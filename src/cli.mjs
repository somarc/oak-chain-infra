import { spawn } from 'node:child_process';
import { access } from 'node:fs/promises';
import { constants as fsConstants } from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';
import { runMockConsole } from './mock-console.mjs';
import { runOpsBoard } from './ops-tui.mjs';

const REPO_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const DEFAULT_TIMEOUT_MS = 10_000;
const DEFAULT_BASE_URL = 'http://127.0.0.1:8090';

const PROFILE_DEFAULTS = {
  'mock-local': { baseUrl: DEFAULT_BASE_URL },
  'sepolia-local': { baseUrl: DEFAULT_BASE_URL },
  'sepolia-readonly': { baseUrl: '' },
  'mainnet-readonly': { baseUrl: '' },
  'prod-readonly': { baseUrl: '' },
};

const READ_COMMANDS = {
  cluster: {
    health: { path: '/v1/ops/snapshots/health' },
    leader: { path: '/v1/consensus/leader' },
    replication: { path: '/v1/ops/snapshots/replication' },
    queue: { path: '/v1/ops/snapshots/queue' },
    status: { path: '/v1/consensus/status' },
  },
  config: {
    coverage: { path: '/v1/config/osgi/coverage' },
    delta: { path: '/v1/config/osgi/delta' },
    schema: { path: '/v1/config/osgi/schema' },
    show: { path: '/v1/config/osgi' },
    sources: { path: '/v1/config/osgi/sources' },
  },
  events: {
    recent: { path: '/v1/events/recent' },
  },
  'release-flow': {
    show: { path: '/v1/proposals/release-flow' },
  },
};

const MOCK_SCRIPT_CANDIDATES = {
  lifecycle: {
    down: [
      'modes/mock/validators/lifecycle/stop-cluster.sh',
    ],
    status: [
      'modes/mock/validators/lifecycle/status-cluster.sh',
    ],
    up: [
      'modes/mock/validators/lifecycle/start-cluster.sh',
    ],
  },
  verify: {
    binary: [
      'modes/mock/validators/tests/integration/test-binary-upload.sh',
      'modes/mock/validators/tests/test-binary-upload.sh',
    ],
    smoke: [
      'modes/mock/validators/tests/smoke/validator-api-smoke.sh',
      'modes/mock/validators/tests/validator-api-smoke.sh',
    ],
    'surfaces-single': [
      'modes/mock/validators/tests/surfaces/proposal-surfaces-single-cluster.sh',
      'modes/mock/validators/tests/proposal-surfaces-single-cluster.sh',
    ],
  },
};

const LAB_SCRIPT_CANDIDATES = {
  '3x2': {
    down: [
      'modes/mock/validators/lifecycle/stop-3x2.sh',
    ],
    status: [
      'modes/mock/validators/lifecycle/status-3x2.sh',
    ],
    up: [
      'modes/mock/validators/lifecycle/start-3x2.sh',
    ],
  },
  incident: {
    triage: [
      'modes/mock/validators/monitoring/triage-validator-logs.sh',
    ],
  },
  verify: {
    staircase: [
      'modes/mock/validators/tests/suites/mock-scale-staircase.sh',
      'modes/mock/validators/tests/mock-scale-staircase.sh',
    ],
    'surfaces-3x2': [
      'modes/mock/validators/tests/surfaces/proposal-surfaces-3x2.sh',
      'modes/mock/validators/tests/proposal-surfaces-3x2.sh',
    ],
  },
};

function print(text = '') {
  process.stdout.write(text);
}

function println(text = '') {
  process.stdout.write(`${text}\n`);
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function parseArgv(argv) {
  const parsed = {
    options: {},
    passthrough: [],
    positionals: [],
  };

  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index];
    if (token === '--') {
      parsed.passthrough = argv.slice(index + 1);
      break;
    }
    if (token === '-h' || token === '--help') {
      parsed.options.help = true;
      continue;
    }
    if (!token.startsWith('--')) {
      parsed.positionals.push(token);
      continue;
    }

    const eq = token.indexOf('=');
    let key;
    let value;

    if (eq >= 0) {
      key = token.slice(2, eq);
      value = token.slice(eq + 1);
    } else {
      key = token.slice(2);
      const next = argv[index + 1];
      if (next !== undefined && next !== '--' && !next.startsWith('--')) {
        value = next;
        index += 1;
      } else {
        value = true;
      }
    }

    parsed.options[key] = value;
  }

  return parsed;
}

function optionValue(options, key, fallback = undefined) {
  return Object.prototype.hasOwnProperty.call(options, key) ? options[key] : fallback;
}

function numberOption(options, key, fallback) {
  const raw = optionValue(options, key, fallback);
  if (raw === undefined || raw === null || raw === '') {
    return fallback;
  }
  const num = Number(raw);
  if (!Number.isFinite(num)) {
    throw new Error(`Invalid --${key} value: ${raw}`);
  }
  return num;
}

function booleanOption(options, key) {
  const raw = optionValue(options, key, false);
  if (typeof raw === 'boolean') {
    return raw;
  }
  if (typeof raw === 'string') {
    const lowered = raw.toLowerCase();
    if (lowered === 'true') return true;
    if (lowered === 'false') return false;
  }
  return Boolean(raw);
}

function normalizeBaseUrl(baseUrl) {
  return String(baseUrl || '').replace(/\/+$/, '');
}

function resolveProfile(options) {
  const selectedProfile = optionValue(options, 'profile', null);
  const profileDefaults = selectedProfile ? PROFILE_DEFAULTS[selectedProfile] : null;
  if (selectedProfile && !profileDefaults) {
    throw new Error(`Unknown --profile: ${selectedProfile}`);
  }

  const baseUrl = normalizeBaseUrl(
    optionValue(options, 'base-url', profileDefaults?.baseUrl ?? DEFAULT_BASE_URL),
  );

  return {
    baseUrl,
    profile: selectedProfile || 'mock-local',
  };
}

function resolveAuthToken(options) {
  return String(
    optionValue(options, 'auth-token', '')
      || process.env.OAK_CLI_AUTH_TOKEN
      || process.env.OAK_VALIDATOR_AUTH_TOKEN
      || process.env.OAK_OPS_API_AUTH_TOKEN
      || process.env.OPS_API_AUTH_TOKEN
      || '',
  ).trim();
}

function resolveUrl(baseUrl, pathOrUrl) {
  if (/^https?:\/\//.test(pathOrUrl)) {
    return pathOrUrl;
  }
  if (!baseUrl) {
    throw new Error('A base URL is required. Pass --base-url or use a profile with a default base URL.');
  }
  const normalizedPath = pathOrUrl.startsWith('/') ? pathOrUrl : `/${pathOrUrl}`;
  return new URL(normalizedPath, `${baseUrl}/`).toString();
}

async function fetchEndpoint(baseUrl, pathOrUrl, options = {}) {
  const url = resolveUrl(baseUrl, pathOrUrl);
  const authToken = resolveAuthToken(options);
  const timeoutMs = numberOption(options, 'timeout-ms', DEFAULT_TIMEOUT_MS);
  const headers = {
    Accept: 'application/json, text/plain;q=0.9, text/event-stream;q=0.8',
  };
  if (authToken) {
    headers.Authorization = authToken;
  }

  const response = await fetch(url, {
    headers,
    signal: timeoutMs > 0 ? AbortSignal.timeout(timeoutMs) : undefined,
  });

  const text = await response.text();
  const contentType = response.headers.get('content-type') || '';
  const body = parseBody(text, contentType);

  if (!response.ok) {
    const detail = typeof body === 'string' ? body : JSON.stringify(body);
    throw new Error(`Request failed for ${url}: ${response.status} ${response.statusText}${detail ? ` - ${detail}` : ''}`);
  }

  return {
    body,
    contentType,
    status: response.status,
    url,
  };
}

async function fetchEndpointSafe(baseUrl, pathOrUrl, options = {}) {
  try {
    const response = await fetchEndpoint(baseUrl, pathOrUrl, options);
    return {
      ok: true,
      body: response.body,
      status: response.status,
      url: response.url,
    };
  } catch (error) {
    return {
      ok: false,
      error: error instanceof Error ? error.message : String(error),
    };
  }
}

function parseBody(text, contentType) {
  const trimmed = text.trim();
  const looksJson = contentType.includes('application/json')
    || trimmed.startsWith('{')
    || trimmed.startsWith('[');

  if (!looksJson) {
    return text;
  }

  try {
    return JSON.parse(text);
  } catch (_error) {
    return text;
  }
}

function getField(target, fieldPath) {
  return fieldPath.split('.').reduce((value, segment) => {
    if (value === undefined || value === null) {
      return undefined;
    }
    const numeric = Number(segment);
    if (Array.isArray(value) && Number.isInteger(numeric) && String(numeric) === segment) {
      return value[numeric];
    }
    return value[segment];
  }, target);
}

function renderOutput(value, options = {}) {
  const selectedValue = optionValue(options, 'field', null)
    ? getField(value, String(optionValue(options, 'field')))
    : value;

  if (typeof selectedValue === 'string') {
    return booleanOption(options, 'raw') ? selectedValue : `${selectedValue}\n`;
  }

  if (selectedValue === undefined) {
    return 'undefined\n';
  }

  return `${JSON.stringify(selectedValue, null, 2)}\n`;
}

async function runReadable(commandName, execute, options) {
  const watchSeconds = numberOption(options, 'watch', 0);

  do {
    const value = await execute();
    if (watchSeconds > 0) {
      println(`--- ${commandName} @ ${new Date().toISOString()} ---`);
    }
    print(renderOutput(value, options));
    if (watchSeconds <= 0) {
      return;
    }
    await sleep(watchSeconds * 1000);
  } while (true);
}

async function runStream(baseUrl, pathOrUrl, options) {
  const url = resolveUrl(baseUrl, pathOrUrl);
  const authToken = resolveAuthToken(options);
  const headers = {
    Accept: 'text/event-stream',
  };
  if (authToken) {
    headers.Authorization = authToken;
  }

  const timeoutMs = numberOption(options, 'timeout-ms', 0);
  const response = await fetch(url, {
    headers,
    signal: timeoutMs > 0 ? AbortSignal.timeout(timeoutMs) : undefined,
  });

  if (!response.ok || !response.body) {
    const body = response.body ? await response.text() : '';
    throw new Error(`Stream failed for ${url}: ${response.status} ${response.statusText}${body ? ` - ${body}` : ''}`);
  }

  const reader = response.body.getReader();
  const decoder = new TextDecoder();

  for (;;) {
    const { done, value } = await reader.read();
    if (done) {
      return;
    }
    process.stdout.write(decoder.decode(value, { stream: true }));
  }
}

function canonicalUrlKey(value) {
  const raw = normalizeBaseUrl(value);
  if (!raw) {
    return '';
  }
  try {
    const parsed = new URL(raw);
    let host = parsed.hostname.toLowerCase();
    if (host === '127.0.0.1' || host === '::1') {
      host = 'localhost';
    }
    const protocol = parsed.protocol.toLowerCase();
    const port = parsed.port || (protocol === 'https:' ? '443' : '80');
    const pathname = parsed.pathname.replace(/\/+$/, '');
    return `${protocol}//${host}:${port}${pathname}`;
  } catch (_error) {
    return raw;
  }
}

function uniqueValues(values) {
  const seen = new Set();
  const result = [];
  for (const value of values) {
    const normalized = String(value || '').trim();
    if (!normalized || seen.has(normalized)) {
      continue;
    }
    seen.add(normalized);
    result.push(normalized);
  }
  return result;
}

function uniqueUrls(values) {
  const seen = new Set();
  const result = [];
  for (const value of values) {
    const raw = normalizeBaseUrl(value);
    if (!raw) {
      continue;
    }
    const key = canonicalUrlKey(raw);
    if (seen.has(key)) {
      continue;
    }
    seen.add(key);
    result.push(raw);
  }
  return result;
}

function peerUrlFromEntry(entry) {
  if (typeof entry === 'string') {
    return normalizeBaseUrl(entry);
  }
  if (!entry || typeof entry !== 'object') {
    return '';
  }
  return normalizeBaseUrl(entry.validatorUrl || entry.url || '');
}

function normalizeLeaderUrl(currentLeader, peerUrl, isLeader) {
  if (typeof currentLeader === 'string' && currentLeader.trim()) {
    return normalizeBaseUrl(currentLeader);
  }
  return isLeader ? normalizeBaseUrl(peerUrl) : null;
}

async function fetchPeerDiscovery(baseUrl, options) {
  const response = await fetchEndpointSafe(baseUrl, '/v1/peers', options);
  const peers = response.ok && Array.isArray(response.body) ? response.body : [];
  return {
    error: response.ok ? null : response.error,
    ok: response.ok,
    peers,
  };
}

function collectPeerUrls(seedUrl, peers, options) {
  const selectedPeer = optionValue(options, 'peer', null);
  if (selectedPeer) {
    return uniqueUrls([selectedPeer]);
  }
  return uniqueUrls([
    normalizeBaseUrl(seedUrl),
    ...peers.map(peerUrlFromEntry),
  ]);
}

function summarizeHealth(result) {
  if (!result.ok) {
    return {
      ok: false,
      error: result.error,
    };
  }
  const body = result.body && typeof result.body === 'object' ? result.body : {};
  return {
    ok: true,
    httpStatus: result.status,
    status: body.status ?? null,
    success: body.success ?? null,
    unhealthyReason: body.unhealthyReason ?? null,
  };
}

function summarizeConsensus(result, peerUrl) {
  if (!result.ok) {
    return {
      ok: false,
      error: result.error,
    };
  }
  const body = result.body && typeof result.body === 'object' ? result.body : {};
  return {
    ok: true,
    consensusType: body.consensusType ?? null,
    currentEpoch: body.currentEpoch ?? null,
    currentLeader: normalizeLeaderUrl(body.currentLeader, peerUrl, body.isLeader === true),
    currentRole: body.currentRole ?? null,
    currentTerm: body.currentTerm ?? null,
    httpStatus: result.status,
    isLeader: body.isLeader ?? null,
    reachableValidators: body.reachableValidators ?? null,
  };
}

function summarizeReplication(result) {
  if (!result.ok) {
    return {
      ok: false,
      error: result.error,
    };
  }
  const body = result.body && typeof result.body === 'object' ? result.body : {};
  const payload = body.data && typeof body.data === 'object' ? body.data : body;
  return {
    ok: true,
    degraded: body.degraded ?? null,
    degradedReason: body.degradedReason ?? null,
    healthy: payload.healthy ?? null,
    httpStatus: result.status,
    reason: payload.reason ?? null,
    replicationLag: payload.replicationLag ?? null,
  };
}

async function buildClusterSnapshot(baseUrl, options) {
  const endpoints = {
    consensus: '/v1/consensus/status',
    health: '/v1/ops/snapshots/health',
    leader: '/v1/consensus/leader',
    peers: '/v1/peers',
    queue: '/v1/ops/snapshots/queue',
    releaseFlow: '/v1/proposals/release-flow',
    replication: '/v1/ops/snapshots/replication',
  };

  const entries = await Promise.all(Object.entries(endpoints).map(async ([name, endpointPath]) => {
    const response = await fetchEndpointSafe(baseUrl, endpointPath, options);
    if (response.ok) {
      return [
        name,
        {
          ok: true,
          path: endpointPath,
          status: response.status,
          data: response.body,
        },
      ];
    }
    return [
      name,
      {
        ok: false,
        path: endpointPath,
        error: response.error,
      },
    ];
  }));

  const sources = Object.fromEntries(entries);
  const discoveredPeers = Array.isArray(sources.peers?.data) ? sources.peers.data : [];

  return {
    baseUrl,
    discoveredPeerCount: discoveredPeers.length,
    discoveredPeerUrls: uniqueUrls(discoveredPeers.map(peerUrlFromEntry)),
    generatedAt: new Date().toISOString(),
    seedUrl: baseUrl,
    sources,
  };
}

async function buildPeerProbe(baseUrl, options) {
  const discovery = await fetchPeerDiscovery(baseUrl, options);
  const peerUrls = collectPeerUrls(baseUrl, discovery.peers, options);

  const probes = await Promise.all(peerUrls.map(async (peerUrl) => {
    const [health, consensus, replication] = await Promise.all([
      fetchEndpointSafe(peerUrl, '/health/local', options),
      fetchEndpointSafe(peerUrl, '/v1/consensus/status', options),
      fetchEndpointSafe(peerUrl, '/v1/ops/snapshots/replication', options),
    ]);

    return {
      consensus: summarizeConsensus(consensus, peerUrl),
      health: summarizeHealth(health),
      ok: health.ok && consensus.ok && replication.ok,
      peerUrl,
      replication: summarizeReplication(replication),
      seed: normalizeBaseUrl(peerUrl) === normalizeBaseUrl(baseUrl),
    };
  }));

  return {
    discovery,
    generatedAt: new Date().toISOString(),
    probes,
    seedUrl: baseUrl,
  };
}

async function buildDoctorReport(baseUrl, options) {
  const probe = await buildPeerProbe(baseUrl, options);
  const findings = [];

  if (!probe.discovery.ok) {
    findings.push({
      code: 'peer_discovery_failed',
      message: probe.discovery.error,
      severity: 'warn',
    });
  }

  for (const entry of probe.probes) {
    if (!entry.health.ok) {
      findings.push({
        code: 'peer_health_unreachable',
        message: `Health probe failed for ${entry.peerUrl}: ${entry.health.error}`,
        peerUrl: entry.peerUrl,
        severity: 'error',
      });
    } else if (entry.health.success === false || entry.health.status === 'UNHEALTHY') {
      findings.push({
        code: 'peer_health_unhealthy',
        message: `Peer reported unhealthy local state${entry.health.unhealthyReason ? `: ${entry.health.unhealthyReason}` : ''}`,
        peerUrl: entry.peerUrl,
        severity: 'error',
      });
    }

    if (!entry.consensus.ok) {
      findings.push({
        code: 'peer_consensus_unreachable',
        message: `Consensus status probe failed for ${entry.peerUrl}: ${entry.consensus.error}`,
        peerUrl: entry.peerUrl,
        severity: 'error',
      });
    }

    if (!entry.replication.ok) {
      findings.push({
        code: 'peer_replication_unreachable',
        message: `Replication probe failed for ${entry.peerUrl}: ${entry.replication.error}`,
        peerUrl: entry.peerUrl,
        severity: 'warn',
      });
    } else if (entry.replication.degraded === false && entry.replication.healthy === false) {
      findings.push({
        code: 'replication_contract_contradiction',
        message: `Replication envelope reports degraded=false while inner health is false${entry.replication.reason ? ` (${entry.replication.reason})` : ''}`,
        peerUrl: entry.peerUrl,
        severity: 'warn',
      });
    }
  }

  const leaders = uniqueUrls(
    probe.probes
      .map((entry) => entry.consensus.currentLeader)
      .filter(Boolean),
  );
  if (leaders.length > 1) {
    findings.push({
      code: 'leader_disagreement',
      message: `Peers disagree on the current leader: ${leaders.join(', ')}`,
      severity: 'error',
    });
  }

  const reachableValidatorCounts = uniqueValues(
    probe.probes
      .map((entry) => entry.consensus.reachableValidators)
      .filter((value) => Number.isFinite(Number(value)))
      .map(String),
  );
  if (reachableValidatorCounts.length > 1) {
    findings.push({
      code: 'reachable_validator_mismatch',
      message: `Peers report inconsistent reachableValidator counts: ${reachableValidatorCounts.join(', ')}`,
      severity: 'warn',
    });
  }

  const status = findings.some((finding) => finding.severity === 'error')
    ? 'error'
    : (findings.length > 0 ? 'warn' : 'ok');

  return {
    findings,
    generatedAt: new Date().toISOString(),
    leaders,
    probedPeers: probe.probes,
    seedUrl: baseUrl,
    status,
    summary: {
      discoveredPeerCount: probe.discovery.peers.length,
      healthyProbeCount: probe.probes.filter((entry) => entry.ok).length,
      probedPeerCount: probe.probes.length,
    },
  };
}

async function locateScript(candidates) {
  for (const relativePath of candidates) {
    const absolutePath = path.join(REPO_ROOT, relativePath);
    try {
      await access(absolutePath, fsConstants.R_OK);
      return absolutePath;
    } catch (_error) {
      // Keep searching.
    }
  }
  throw new Error(`No script found. Checked: ${candidates.join(', ')}`);
}

function spawnScript(scriptPath, passthrough, dryRun) {
  if (dryRun) {
    println(JSON.stringify({
      argv: passthrough,
      cwd: REPO_ROOT,
      script: scriptPath,
    }, null, 2));
    return Promise.resolve(0);
  }

  return new Promise((resolve, reject) => {
    const child = spawn('bash', [scriptPath, ...passthrough], {
      cwd: REPO_ROOT,
      env: process.env,
      stdio: 'inherit',
    });

    child.on('error', reject);
    child.on('exit', (code) => {
      if (code === 0) {
        resolve(0);
        return;
      }
      reject(new Error(`Script exited with code ${code}: ${scriptPath}`));
    });
  });
}

async function runMockCommand(action, third, passthrough, dryRun) {
  let candidates;
  let usage;

  if (action === 'up' || action === 'down' || action === 'status') {
    candidates = MOCK_SCRIPT_CANDIDATES.lifecycle[action];
    usage = 'Usage: oak-chain mock up|down|status [--dry-run] [-- <script args...>]';
  } else if (action === 'verify') {
    if (third === 'surfaces-3x2' || third === 'staircase') {
      throw new Error('Topology verify flows moved under lab. Use oak-chain lab verify surfaces-3x2|staircase.');
    }
    if (!third || !MOCK_SCRIPT_CANDIDATES.verify[third]) {
      throw new Error('Usage: oak-chain mock verify smoke|binary|surfaces-single [--dry-run] [-- <script args...>]');
    }
    candidates = MOCK_SCRIPT_CANDIDATES.verify[third];
    usage = 'Usage: oak-chain mock verify smoke|binary|surfaces-single [--dry-run] [-- <script args...>]';
  } else if (action === '3x2') {
    throw new Error('3x2 topology commands moved under lab. Use oak-chain lab 3x2 up|down|status.');
  } else if (action === 'incident') {
    throw new Error('Incident triage moved under lab. Use oak-chain lab incident triage.');
  } else {
    throw new Error('Usage: oak-chain mock up|down|status|console | oak-chain mock verify smoke|binary|surfaces-single');
  }

  if (!candidates || candidates.length === 0) {
    throw new Error(usage);
  }

  const scriptPath = await locateScript(candidates);
  await spawnScript(scriptPath, passthrough, dryRun);
}

async function runLabCommand(action, third, passthrough, dryRun) {
  let candidates;
  let usage;

  if (action === '3x2') {
    if (!third || !LAB_SCRIPT_CANDIDATES['3x2'][third]) {
      throw new Error('Usage: oak-chain lab 3x2 up|down|status [--dry-run] [-- <script args...>]');
    }
    candidates = LAB_SCRIPT_CANDIDATES['3x2'][third];
    usage = 'Usage: oak-chain lab 3x2 up|down|status [--dry-run] [-- <script args...>]';
  } else if (action === 'verify') {
    if (!third || !LAB_SCRIPT_CANDIDATES.verify[third]) {
      throw new Error('Usage: oak-chain lab verify surfaces-3x2|staircase [--dry-run] [-- <script args...>]');
    }
    candidates = LAB_SCRIPT_CANDIDATES.verify[third];
    usage = 'Usage: oak-chain lab verify surfaces-3x2|staircase [--dry-run] [-- <script args...>]';
  } else if (action === 'incident') {
    if (!third || !LAB_SCRIPT_CANDIDATES.incident[third]) {
      throw new Error('Usage: oak-chain lab incident triage [--dry-run] [-- <script args...>]');
    }
    candidates = LAB_SCRIPT_CANDIDATES.incident[third];
    usage = 'Usage: oak-chain lab incident triage [--dry-run] [-- <script args...>]';
  } else {
    throw new Error('Usage: oak-chain lab 3x2 up|down|status | oak-chain lab verify surfaces-3x2|staircase | oak-chain lab incident triage');
  }

  if (!candidates || candidates.length === 0) {
    throw new Error(usage);
  }

  const scriptPath = await locateScript(candidates);
  await spawnScript(scriptPath, passthrough, dryRun);
}

function printHelp() {
  println('oak-chain v0');
  println('');
  println('Single-cluster operator CLI for Oak Chain validators, with mock-local single-cluster helpers and a separate lab namespace for topology tests.');
  println('');
  println('Usage:');
  println('  oak-chain cluster snapshot [--base-url URL] [--watch SEC]');
  println('  oak-chain cluster leader|status|health|queue|replication [--base-url URL]');
  println('  oak-chain peer list [--base-url URL]');
  println('  oak-chain peer probe [--base-url URL] [--peer URL]');
  println('  oak-chain proposal status <proposalId> [--base-url URL]');
  println('  oak-chain release-flow show [--base-url URL]');
  println('  oak-chain config show|schema|sources|coverage|delta [--base-url URL]');
  println('  oak-chain events recent [--base-url URL]');
  println('  oak-chain events tail [--base-url URL]');
  println('  oak-chain api get <path> [--base-url URL]');
  println('  oak-chain doctor [--base-url URL] [--peer URL]');
  println('  oak-chain ops board [--ops-url URL] [--interval-ms N] [--once]');
  println('  oak-chain mock up|down|status [--dry-run] [-- <script args...>]');
  println('  oak-chain mock console [--runtime-root PATH] [--cluster-size 3|5] [--lifecycle-dir PATH] [--once]');
  println('  oak-chain mock verify smoke|binary|surfaces-single [--dry-run] [-- <script args...>]');
  println('  oak-chain lab 3x2 up|down|status [--dry-run] [-- <script args...>]');
  println('  oak-chain lab verify surfaces-3x2|staircase [--dry-run] [-- <script args...>]');
  println('  oak-chain lab incident triage [--dry-run] [-- <script args...>]');
  println('');
  println('Global options:');
  println('  --base-url URL      Override the seed validator URL.');
  println('  --ops-url URL       Override the governed OPS adapter URL (default http://127.0.0.1:8787).');
  println('  --profile NAME      mock-local, sepolia-local, sepolia-readonly, mainnet-readonly, prod-readonly.');
  println('  --auth-token TOKEN  Send Authorization header for remote commands.');
  println('  --watch SEC         Re-run read commands on an interval.');
  println('  --timeout-ms N      HTTP timeout for remote commands. Use 0 for no timeout.');
  println('  --field a.b.c       Extract a nested field from JSON output.');
  println('  --peer URL          Restrict peer probe or doctor to one discovered peer.');
  println('  --raw               Print raw string output without pretty JSON wrapping.');
  println('  --json              Accepted for compatibility; JSON is the default output.');
  println('  --dry-run           Print the script invocation instead of executing it.');
  println('  --once              Render one OPS board snapshot and exit.');
  println('  --interval-ms N     OPS board refresh interval (default 2000).');
  println('  --runtime-root PATH Local runtime root used for mock log aggregation.');
  println('  --no-local-logs     Disable local active-log aggregation.');
  println('  --cluster-size N    Mock console: member count (3 or 5); overrides env and the launch record.');
  println('  --lifecycle-dir P   Mock console: lifecycle scripts to drive (default modes/mock/validators/lifecycle).');
  println('  --color             Force ANSI colour, including one-shot output.');
  println('  --no-color          Disable ANSI colour (also honors NO_COLOR).');
  println('  -h, --help          Show this help.');
}

function movedToMockMessage(group) {
  if (group === 'local') {
    return 'local commands moved under mock. Use oak-chain mock up|down|status.';
  }
  if (group === 'verify') {
    return 'verify commands are split: single-cluster flows use oak-chain mock verify ..., topology flows use oak-chain lab verify ....';
  }
  if (group === 'incident') {
    return 'incident commands moved under lab. Use oak-chain lab incident triage.';
  }
  return '';
}

export async function main(argv = process.argv.slice(2)) {
  const parsed = parseArgv(argv);
  const [group, action, third] = parsed.positionals;

  if (!group || parsed.options.help) {
    printHelp();
    return;
  }

  const profile = resolveProfile(parsed.options);
  const dryRun = booleanOption(parsed.options, 'dry-run');

  if (group === 'local' || group === 'verify' || group === 'incident') {
    throw new Error(movedToMockMessage(group));
  }

  if (group === 'api' && action === 'get') {
    if (!third) {
      throw new Error('Usage: oak-chain api get <path>');
    }
    await runReadable(`api get ${third}`, async () => {
      const response = await fetchEndpoint(profile.baseUrl, third, parsed.options);
      return response.body;
    }, parsed.options);
    return;
  }

  if (group === 'cluster' && action === 'snapshot') {
    await runReadable('cluster snapshot', async () => buildClusterSnapshot(profile.baseUrl, parsed.options), parsed.options);
    return;
  }

  if (READ_COMMANDS[group]?.[action]) {
    const spec = READ_COMMANDS[group][action];
    await runReadable(`${group} ${action}`, async () => {
      const response = await fetchEndpoint(profile.baseUrl, spec.path, parsed.options);
      return response.body;
    }, parsed.options);
    return;
  }

  if (group === 'peer' && action === 'list') {
    await runReadable('peer list', async () => {
      const discovery = await fetchPeerDiscovery(profile.baseUrl, parsed.options);
      if (!discovery.ok) {
        throw new Error(discovery.error);
      }
      return discovery.peers;
    }, parsed.options);
    return;
  }

  if (group === 'peer' && action === 'probe') {
    await runReadable('peer probe', async () => buildPeerProbe(profile.baseUrl, parsed.options), parsed.options);
    return;
  }

  if (group === 'proposal' && action === 'status') {
    if (!third) {
      throw new Error('Usage: oak-chain proposal status <proposalId>');
    }
    await runReadable(`proposal status ${third}`, async () => {
      const response = await fetchEndpoint(profile.baseUrl, `/v1/proposals/${encodeURIComponent(third)}/status`, parsed.options);
      return response.body;
    }, parsed.options);
    return;
  }

  if (group === 'events' && action === 'tail') {
    await runStream(profile.baseUrl, '/v1/events/stream', parsed.options);
    return;
  }

  if (group === 'doctor' && !action) {
    await runReadable('doctor', async () => buildDoctorReport(profile.baseUrl, parsed.options), parsed.options);
    return;
  }

  if (group === 'ops' && action === 'board') {
    await runOpsBoard(parsed.options);
    return;
  }

  if (group === 'mock' && action === 'console') {
    await runMockConsole(parsed.options, { repoRoot: REPO_ROOT });
    return;
  }

  if (group === 'mock') {
    await runMockCommand(action, third, parsed.passthrough, dryRun);
    return;
  }

  if (group === 'lab') {
    await runLabCommand(action, third, parsed.passthrough, dryRun);
    return;
  }

  throw new Error(`Unknown command: ${[group, action, third].filter(Boolean).join(' ')}`);
}
