// Enterprise-federation 3x2 live smoke (modes/mock/validators/tests/routing/federation-3x2-smoke.sh).
//
// Assumes both federation clusters are already running (lifecycle/start-fed-3x2.sh) and never
// starts, stops or signals anything. It writes the shared static directory file, sends fewer than
// 30 signed writes/deletes, and records everything in one immutable evidence directory:
//
//   $FED_3X2_ROOT/evidence/<UTC timestamp>/
//     manifest.json        provenance: git SHAs and dirty state, jar path + sha256, java -version,
//                          ports, PIDs with exact command lines, launch records, log offsets
//     requests.ndjson      every request/response (status, headers incl. Location, body)
//     snapshots/<phase>/   GET /v1/federation and /health of all six members per phase
//     directory-epoch-N.json  each directory file this run wrote
//     log-scan.json        ERROR lines appended to the validator logs during the run
//     assertions.tsv       phase | assertionId | kind | expected | observed | status | evidence | note
//     summary.json, report.md
//
// Phases: P0 preflight, P1 charter, P2 directory epoch E1, P3 writes and deletes, P4 cross-cluster
// reads through the directory mounts, P5 directory epoch E2 (writer removed), P6 end state.
// Bounded: every wait has a deadline; the first unexpected 5xx or a member that stops answering
// aborts the run (everything stays running for inspection). A required assertion that is not
// PASS fails the run; UNKNOWN fails it too.

import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import {
  appendFileSync, chmodSync, closeSync, existsSync, mkdirSync, openSync, readFileSync, readSync, readdirSync,
  realpathSync, renameSync, statSync, writeFileSync,
} from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

import { classifyOperation } from './harness/client.mjs';
import { STATUS, summarize } from './harness/evidence.mjs';
import { buildDelete, buildWrite, testKey } from './tx.mjs';

export const DEFAULTS = Object.freeze({
  deadlineMs: 60_000,
  maxWrites: 30,
  pollMs: 2_000,
  requestTimeoutMs: 10_000,
});

// Test wallets: deterministic public test keys (modes/mock/lib/test-wallets.tsv client-N rows).
export const WALLET_ROLES = Object.freeze({
  nsA1: 1, // namespace owned by enterprise A, written by its own wallet
  nsA2: 2, // namespace owned by enterprise A, written by the listed writer wA
  nsB1: 3, // namespace owned by enterprise B
  wA: 4, // enterprise A's listed writer (removed at epoch E2)
  stranger: 5, // neither a namespace wallet nor a writer
  unclaimed: 6, // a namespace no enterprise claims
});

class Abort extends Error {}

const sleepDefault = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

export function utcStamp(date) {
  return date.toISOString().replace(/[-:]/g, '').replace(/\.\d+Z$/, 'Z');
}

// Mirrors lifecycle/lib/fed-3x2.sh: the federation root never is, contains or sits under a
// protected live root ($HOME/oak-chain plus OAK_PROTECTED_ROOTS).
export function federationRootProblem(root, { home, protectedRoots = '' } = {}) {
  if (!root) return 'the federation root is empty';
  if (!path.isAbsolute(root)) return `the federation root must be an absolute path: ${root}`;
  if (/\s/.test(root)) return `the federation root must not contain whitespace: ${root}`;
  const normalized = path.resolve(root);
  if (normalized === '/' || normalized === path.resolve(home)) return `the federation root must be a dedicated directory, not ${normalized}`;
  const physical = (p) => {
    let existing = p;
    const rest = [];
    while (!existsSync(existing) && existing !== path.dirname(existing)) {
      rest.unshift(path.basename(existing));
      existing = path.dirname(existing);
    }
    try {
      return path.join(realpathSync(existing), ...rest);
    } catch {
      return p;
    }
  };
  const protectedList = [path.join(home, 'oak-chain'), ...String(protectedRoots).split(':').filter(Boolean)];
  for (const raw of protectedList) {
    for (const form of new Set([normalized, physical(normalized)])) {
      for (const p of new Set([path.resolve(raw), physical(path.resolve(raw))])) {
        if (form === p || form.startsWith(`${p}/`)) return `the federation root ${normalized} is (or is under) the protected live root ${raw}`;
        if (p.startsWith(`${form}/`)) return `the federation root ${normalized} contains the protected live root ${raw}`;
      }
    }
  }
  return null;
}

export function clusterMembers(cluster) {
  if (Array.isArray(cluster.members)) {
    return cluster.members.map((member, index) => ({ index, port: member.port, url: `http://127.0.0.1:${member.port}` }));
  }
  return Array.from({ length: cluster.size ?? 3 }, (_, index) => {
    const port = cluster.httpBase + index * (cluster.httpStep ?? 2);
    return { index, port, url: `http://127.0.0.1:${port}` };
  });
}

// The directory file this smoke writes for epoch N. The runtime defaults chainId/registry from the charter.
export function directoryDocument({ clusters, epoch, wallets, writersA }) {
  const [a, b] = clusters;
  return {
    directoryEpoch: epoch,
    entries: [
      {
        endpoints: clusterMembers(a).map((member) => member.url),
        enterpriseId: a.enterpriseId,
        namespaces: [wallets.nsA1, wallets.nsA2],
        status: 'ACTIVE',
        writers: writersA,
      },
      {
        endpoints: clusterMembers(b).map((member) => member.url),
        enterpriseId: b.enterpriseId,
        namespaces: [wallets.nsB1],
        status: 'ACTIVE',
        writers: [],
      },
    ],
  };
}

// Shard levels of an address (WalletPathUtil): the first three bytes of the address.
export function namespaceRoot(address) {
  const hex = address.slice(2);
  return `/oak-chain/${hex.slice(0, 2)}/${hex.slice(2, 4)}/${hex.slice(4, 6)}/${address}`;
}

const sorted = (values) => [...(values ?? [])].map(String).sort();
const sameList = (left, right) => JSON.stringify(sorted(left)) === JSON.stringify(sorted(right));
const short = (value) => (typeof value === 'string' && value.length > 18 ? `${value.slice(0, 12)}…` : value);

function sha256File(file) {
  const hash = createHash('sha256');
  hash.update(readFileSync(file));
  return hash.digest('hex');
}

function defaultExec(command, args, { cwd } = {}) {
  const result = spawnSync(command, args, { cwd, encoding: 'utf8', timeout: 15_000 });
  return { code: result.status, stderr: result.stderr ?? '', stdout: result.stdout ?? '', error: result.error?.message ?? null };
}

function gitState(exec, dir) {
  if (!dir) return null;
  const top = exec('git', ['-C', dir, 'rev-parse', '--show-toplevel']);
  if (top.code !== 0) return { dir, error: (top.stderr || top.error || 'not a git checkout').trim() };
  const root = top.stdout.trim();
  const status = exec('git', ['-C', root, 'status', '--porcelain']).stdout.split('\n').filter(Boolean);
  return {
    branch: exec('git', ['-C', root, 'rev-parse', '--abbrev-ref', 'HEAD']).stdout.trim(),
    dirty: status.length > 0,
    dirtyFiles: status.slice(0, 50),
    head: exec('git', ['-C', root, 'rev-parse', 'HEAD']).stdout.trim(),
    root,
  };
}

function parseRecord(text) {
  const out = {};
  for (const line of String(text ?? '').split('\n')) {
    if (!line || line.startsWith('#') || !line.includes('=')) continue;
    out[line.slice(0, line.indexOf('='))] = line.slice(line.indexOf('=') + 1);
  }
  return out;
}

function readIf(file) {
  try {
    return readFileSync(file, 'utf8');
  } catch {
    return null;
  }
}

function fileSize(file) {
  try {
    return statSync(file).size;
  } catch {
    return null;
  }
}

function readFrom(file, offset) {
  const size = fileSize(file);
  if (size === null) return null;
  const start = offset !== null && offset <= size ? offset : 0;
  const fd = openSync(file, 'r');
  try {
    const buffer = Buffer.alloc(size - start);
    readSync(fd, buffer, 0, buffer.length, start);
    return buffer.toString('utf8');
  } finally {
    closeSync(fd);
  }
}

function sealEvidence(dir) {
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) sealEvidence(full);
    else chmodSync(full, 0o444);
  }
  chmodSync(dir, 0o555);
}

function cell(value) {
  if (value === undefined || value === null) return '';
  const text = typeof value === 'string' ? value : JSON.stringify(value);
  return text.replace(/[\t\r\n]+/g, ' ');
}

export async function runFederationSmoke(config, {
  env = process.env,
  exec = defaultExec,
  fetchImpl = globalThis.fetch,
  log = (line) => process.stdout.write(`${line}\n`),
  now = () => new Date(),
  seal = true,
  sleep = sleepDefault,
} = {}) {
  const opts = { ...DEFAULTS, ...config.options };
  const home = env.HOME;
  const problem = federationRootProblem(config.fedRoot, { home, protectedRoots: env.OAK_PROTECTED_ROOTS });
  if (problem) throw new Error(`Refusing federation smoke: ${problem}`);
  if (!Array.isArray(config.clusters) || config.clusters.length !== 2) throw new Error('config.clusters must hold cluster A and cluster B');
  for (const cluster of config.clusters) {
    const expectedRoot = path.join(config.fedRoot, `cluster-${cluster.label}`);
    if (cluster.runtimeRoot && path.resolve(cluster.runtimeRoot) !== expectedRoot) {
      throw new Error(`Refusing federation smoke: cluster ${cluster.label} runtime root ${cluster.runtimeRoot} is not ${expectedRoot}`);
    }
  }
  const directoryFile = config.directoryFile ?? path.join(config.fedRoot, 'directory.json');
  if (path.dirname(path.resolve(directoryFile)) !== path.resolve(config.fedRoot)) {
    throw new Error(`Refusing federation smoke: directory file ${directoryFile} is not directly under ${config.fedRoot}`);
  }

  const startedAt = now();
  const evidenceRoot = path.join(config.fedRoot, 'evidence');
  mkdirSync(evidenceRoot, { recursive: true });
  const dir = path.join(evidenceRoot, utcStamp(startedAt));
  mkdirSync(dir); // throws EEXIST: an evidence directory is never reused
  mkdirSync(path.join(dir, 'snapshots'));

  const clusters = config.clusters.map((cluster) => ({ ...cluster, members: clusterMembers(cluster) }));
  const [A, B] = clusters;
  const allMembers = clusters.flatMap((cluster) => cluster.members.map((member) => ({ ...member, cluster })));
  const wallets = Object.fromEntries(Object.entries(WALLET_ROLES).map(([role, index]) => [role, testKey(index)]));
  const addr = Object.fromEntries(Object.entries(wallets).map(([role, key]) => [role, key.address]));
  const nonce = `${utcStamp(startedAt)}-${process.pid}`;
  const assertions = [];
  const stats = { allowed5xx: [], requests: 0, unexpected5xx: [], writes: 0 };
  let seq = 0;
  let phase = 'P0';

  const write = (name, value) => writeFileSync(path.join(dir, name), typeof value === 'string' ? value : `${JSON.stringify(value, null, 2)}\n`);
  const assert = (id, { evidence = '', expected, kind = 'required', note = '', observed, ok }) => {
    const status = ok === true ? STATUS.PASS : ok === false ? STATUS.FAIL : STATUS.UNKNOWN;
    assertions.push({ assertionId: id, evidence, expected, kind, note, observed, scenarioId: phase, status });
    log(`  ${status === STATUS.PASS ? '✅' : status === STATUS.FAIL ? '❌' : '❔'} ${phase} ${id}: ${cell(observed).slice(0, 160)}`);
    return status === STATUS.PASS;
  };

  // Every request goes through here: recorded verbatim, then classified.
  async function call(label, method, url, { allow5xx = () => false, form = null, tolerate = false } = {}) {
    seq += 1;
    stats.requests += 1;
    const id = seq;
    const at = new Date().toISOString();
    const started = Date.now();
    const headers = {};
    let status = 0;
    let text = '';
    let error = null;
    try {
      const response = await fetchImpl(url, {
        body: form ? new URLSearchParams(form).toString() : undefined,
        headers: form ? { Accept: 'application/json', 'Content-Type': 'application/x-www-form-urlencoded' } : { Accept: 'application/json' },
        method,
        redirect: 'manual',
        signal: AbortSignal.timeout(opts.requestTimeoutMs),
      });
      status = response.status;
      response.headers.forEach((value, key) => { headers[key] = value; });
      text = await response.text();
    } catch (caught) {
      error = caught instanceof Error ? caught.message : String(caught);
    }
    let json = null;
    try {
      json = text ? JSON.parse(text) : null;
    } catch {
      json = null;
    }
    const record = {
      at, body: json ?? text, durationMs: Date.now() - started, error, headers, label, location: headers.location ?? null,
      method, phase, request: form, seq: id, status, url,
    };
    appendFileSync(path.join(dir, 'requests.ndjson'), `${JSON.stringify(record)}\n`);
    const result = { error, headers, json, location: headers.location ?? null, seq: id, status, text, url };
    if (tolerate) return result;
    if (status === 0) throw new Abort(`member down: ${method} ${url} did not answer (${error}) [requests.ndjson#${id}]`);
    if (status >= 500) {
      if (allow5xx(status, json)) {
        stats.allowed5xx.push({ label, seq: id, status, code: json?.code ?? null });
      } else {
        stats.unexpected5xx.push({ label, seq: id, status });
        throw new Abort(`unexpected HTTP ${status} from ${label} (${method} ${url}) [requests.ndjson#${id}]`);
      }
    }
    return result;
  }

  async function waitFor(what, probe) {
    const started = Date.now();
    const deadline = started + opts.deadlineMs;
    let last;
    for (;;) {
      last = await probe();
      if (last.done) return { ...last, ok: true, waitedMs: Date.now() - started };
      if (Date.now() >= deadline) {
        log(`  ⏱  ${what}: deadline (${opts.deadlineMs} ms) reached`);
        return { ...last, ok: false, waitedMs: Date.now() - started };
      }
      await sleep(opts.pollMs);
    }
  }

  async function federationViews(label, extra = {}) {
    const views = [];
    for (const member of allMembers) {
      const response = await call(`${label} ${member.cluster.label}${member.index}`, 'GET', `${member.url}/v1/federation`, extra);
      views.push({ member, response, view: response.json ?? {} });
    }
    return views;
  }

  async function snapshot(name, tolerate = false) {
    const target = path.join(dir, 'snapshots', name);
    mkdirSync(target, { recursive: true });
    for (const member of allMembers) {
      for (const [kind, route] of [['federation', '/v1/federation'], ['health', '/health']]) {
        const response = await call(`snapshot ${name} ${member.cluster.label}${member.index} ${kind}`, 'GET', `${member.url}${route}`, { tolerate });
        writeFileSync(path.join(target, `${member.cluster.label}${member.index}-${kind}.json`),
          `${JSON.stringify({ body: response.json ?? response.text, seq: response.seq, status: response.status, url: response.url }, null, 2)}\n`);
      }
    }
    return `snapshots/${name}`;
  }

  async function leaderOf(cluster) {
    const found = await waitFor(`leader of cluster ${cluster.label}`, async () => {
      const leaders = [];
      for (const member of cluster.members) {
        const response = await call(`leader probe ${cluster.label}${member.index}`, 'GET', `${member.url}/v1/consensus/status`);
        if (response.json?.currentRole === 'LEADER') leaders.push(member);
      }
      return { done: leaders.length === 1, leaders };
    });
    if (!found.ok) throw new Abort(`cluster ${cluster.label} has ${found.leaders.length} leaders after ${opts.deadlineMs} ms`);
    return found.leaders[0];
  }

  // POST a signed write or delete. Follows a leader redirect within the same cluster (never a
  // wrong_cluster redirect) and retries no_quorum like the 3x2 smokes; every attempt is recorded.
  async function submit(label, cluster, member, form, route = '/v1/propose-write', { follow = true } = {}) {
    let target = `${member.url}${route}`;
    let response;
    for (let attempt = 0; attempt < 6; attempt += 1) {
      stats.writes += 1;
      if (stats.writes > opts.maxWrites) throw new Abort(`write budget of ${opts.maxWrites} requests exhausted`);
      const noQuorum = (status, json) => status === 503 && JSON.stringify(json ?? '').includes('no_quorum');
      response = await call(label, 'POST', target, { allow5xx: noQuorum, form });
      if (noQuorum(response.status, response.json)) {
        await sleep(opts.pollMs);
        continue;
      }
      const sameCluster = response.location && cluster.members.some((m) => response.location.startsWith(`${m.url}/`)
        || response.location.startsWith(`http://localhost:${m.port}/`));
      if (follow && response.status === 307 && response.json?.code !== 'wrong_cluster' && sameCluster) {
        target = response.location.replace('//localhost:', '//127.0.0.1:');
        continue;
      }
      return response;
    }
    return response;
  }

  async function committed(label, cluster, proposalId) {
    return waitFor(`${label} committed`, async () => {
      const leader = await leaderOf(cluster);
      const response = await call(`${label} operation`, 'GET', `${leader.url}/v1/ops/operations/${proposalId}`);
      const verdict = response.status === 200 ? classifyOperation(response.json) : null;
      return { done: Boolean(verdict), seq: response.seq, state: response.json?.state ?? `http ${response.status}`, verdict };
    });
  }

  async function contentOn(label, members, namespace, message, { remote = false } = {}) {
    const seen = {};
    const result = await waitFor(label, async () => {
      for (const member of members) {
        if (seen[member.url]?.found) continue;
        const response = await call(`${label} ${member.url}`, 'GET', `${member.url}/v1/wallets/content?wallet=${namespace}`, {
          allow5xx: (status) => remote && status === 503,
        });
        const items = Array.isArray(response.json?.content) ? response.json.content : [];
        seen[member.url] = { found: items.some((item) => item.message === message), seq: response.seq, status: response.status };
      }
      return { done: members.every((m) => seen[m.url]?.found), seen };
    });
    return result;
  }

  const expectStatus = (response, status, code) => response.status === status && (code === undefined || response.json?.code === code);
  const observedOf = (response) => `${response.status} ${response.json?.code ?? ''}`.trim();

  // ── manifest (before any mutation) ─────────────────────────────────────────────────────────
  const jarPath = env.OAK_CONSENSUS_JAR || null;
  const jarSourceDir = env.FED_JAR_SOURCE_DIR || (jarPath ? path.dirname(jarPath) : null);
  const memberFacts = [];
  for (const cluster of clusters) {
    const record = parseRecord(readIf(path.join(cluster.pidDir ?? '', 'cluster-launch.env')));
    cluster.launchRecord = record;
    for (const member of cluster.members) {
      const pid = (readIf(path.join(cluster.pidDir ?? '', `validator-${member.index}.pid`)) ?? '').trim() || null;
      const command = pid ? exec('ps', ['-p', pid, '-o', 'command=']).stdout.trim() || null : null;
      const logFile = cluster.logDir ? path.join(cluster.logDir, `validator-${member.index}.log`) : null;
      memberFacts.push({
        cluster: cluster.label, command, index: member.index, logFile, logOffset: logFile ? fileSize(logFile) : null, pid, url: member.url,
      });
    }
  }
  const java = exec('java', ['-version']);
  const manifest = {
    clusters: clusters.map((cluster) => ({
      aeronPorts: cluster.aeronBase ? `${cluster.aeronBase}-${cluster.aeronBase + (cluster.members.length - 1) * 100 + 6}` : null,
      enterpriseId: cluster.enterpriseId,
      httpPorts: cluster.members.map((member) => member.port),
      label: cluster.label,
      launchRecord: cluster.launchRecord,
      logDir: cluster.logDir ?? null,
      name: cluster.name,
      opsPort: cluster.opsPort ?? null,
      pidDir: cluster.pidDir ?? null,
      runtimeRoot: cluster.runtimeRoot ?? null,
      standbyPorts: cluster.members.map((member) => member.port + 1),
    })),
    command: config.command ?? process.argv.join(' '),
    cwd: process.cwd(),
    directoryFile,
    evidenceDir: dir,
    fedRoot: config.fedRoot,
    git: { infra: gitState(exec, config.infraDir ?? process.cwd()), jackrabbitOak: jarSourceDir ? gitState(exec, jarSourceDir) : null },
    jar: { path: jarPath, sha256: jarPath && existsSync(jarPath) ? sha256File(jarPath) : null, sourceDir: jarSourceDir },
    java: (java.stderr || java.stdout || java.error || '').trim(),
    members: memberFacts,
    node: process.version,
    nonce,
    options: opts,
    startedAt: startedAt.toISOString(),
    wallets: Object.fromEntries(Object.entries(wallets).map(([role, key]) => [role, { address: key.address, keyIndex: key.index }])),
  };
  write('manifest.json', manifest);
  log(`🧾 Evidence: ${dir}`);

  let aborted = null;
  const directoryDigests = {};
  try {
    // ── P0 preflight ──────────────────────────────────────────────────────────────────────────
    phase = 'P0';
    log('━━ P0 preflight');
    const up = await waitFor('all members answer /health/local', async () => {
      const codes = {};
      for (const member of allMembers) {
        codes[member.url] = (await call(`preflight ${member.cluster.label}${member.index}`, 'GET', `${member.url}/health/local`, { tolerate: true })).status;
      }
      return { codes, done: Object.values(codes).every((code) => code === 200) };
    });
    assert('members-up', { expected: 'all 6 members answer /health/local 200', observed: up.codes, ok: up.ok });
    if (!up.ok) throw new Abort('not every member is up');
    const pidsKnown = memberFacts.every((fact) => fact.pid && fact.command && fact.command.includes(`validator-${fact.index}`));
    assert('pids-recorded', { expected: 'a live pid per member whose command line names its store', observed: memberFacts.map((f) => `${f.cluster}${f.index}:${f.pid ?? '-'}`), ok: pidsKnown || null, note: pidsKnown ? '' : 'pid files or ps unavailable' });
    const jarShas = clusters.map((cluster) => cluster.launchRecord.OAK_CONSENSUS_JAR_SHA256 || null);
    const jarAgrees = jarShas.every((sha) => sha && sha === jarShas[0]) && (!manifest.jar.sha256 || manifest.jar.sha256 === jarShas[0]);
    assert('same-jar', { expected: 'both launch records pin one OAK_CONSENSUS_JAR sha256 (= the env jar, when given)', observed: { env: manifest.jar.sha256, records: jarShas }, ok: jarShas.every(Boolean) ? jarAgrees : null });
    for (const cluster of clusters) {
      const opts2 = cluster.launchRecord.EXTRA_JAVA_OPTS ?? '';
      assert(`launch-config-${cluster.label}`, {
        expected: `EXTRA_JAVA_OPTS has enterpriseId ${short(cluster.enterpriseId)}, mode=mock, registry=static, directoryFile, no oak.sharding.*`,
        observed: opts2 || '(no launch record)',
        ok: opts2 ? opts2.includes(`-Doak.federation.enterpriseId=${cluster.enterpriseId}`) && opts2.includes('-Doak.federation.mode=mock')
          && opts2.includes('-Doak.federation.registry=static') && opts2.includes(`-Doak.federation.directoryFile=${directoryFile}`)
          && !opts2.includes('oak.sharding.') : null,
      });
    }

    // ── P1 charter ────────────────────────────────────────────────────────────────────────────
    phase = 'P1';
    log('━━ P1 charter');
    const charters = await waitFor('charter committed on all members', async () => {
      const views = await federationViews('P1 federation');
      return { done: views.every(({ view }) => view.charter?.enterpriseId && view.charterDigest && view.clusterId), views };
    });
    const p1 = await snapshot('P1-charter');
    const clusterIds = {};
    for (const cluster of clusters) {
      const views = charters.views.filter(({ member }) => member.cluster === cluster);
      const ev = `${p1}; requests.ndjson#${views.map((v) => v.response.seq).join(',')}`;
      const ids = views.map(({ view }) => view.charter?.enterpriseId?.toLowerCase());
      const digests = new Set(views.map(({ view }) => view.charterDigest));
      const cids = new Set(views.flatMap(({ view }) => [view.clusterId, view.status?.clusterId]));
      clusterIds[cluster.label] = [...cids][0];
      assert(`charter-enterprise-${cluster.label}`, { evidence: ev, expected: cluster.enterpriseId, observed: ids, ok: charters.ok ? ids.every((id) => id === cluster.enterpriseId) : false });
      assert(`charter-digest-uniform-${cluster.label}`, { evidence: ev, expected: 'one charterDigest across 3 members', observed: [...digests], ok: digests.size === 1 && !digests.has(undefined) });
      assert(`cluster-id-uniform-${cluster.label}`, { evidence: ev, expected: 'one clusterId (top level and status) across 3 members', observed: [...cids], ok: cids.size === 1 && !cids.has(undefined) && !cids.has(null) });
      assert(`charter-matches-config-${cluster.label}`, { evidence: ev, expected: 'status.charterMatchesConfig=true on 3 members', observed: views.map(({ view }) => view.status?.charterMatchesConfig), ok: views.every(({ view }) => view.status?.charterMatchesConfig === true) });
      assert(`charter-fields-${cluster.label}`, {
        evidence: ev, expected: 'mode=mock registry=static chainId=0',
        observed: views.map(({ view }) => `${view.charter?.mode}/${view.charter?.registry}/${view.charter?.chainId}`),
        ok: views.every(({ view }) => view.charter?.mode === 'mock' && view.charter?.registry === 'static' && Number(view.charter?.chainId) === 0),
      });
    }
    assert('cluster-ids-differ', { evidence: p1, expected: 'cluster A and cluster B report different clusterIds', observed: clusterIds, ok: Boolean(clusterIds.a && clusterIds.b && clusterIds.a !== clusterIds.b) });
    if (!charters.ok) throw new Abort('the charter was not committed on every member');

    const committedEpochs = charters.views.map(({ view }) => Number(view.status?.directoryEpoch ?? view.directory?.directoryEpoch ?? 0) || 0);
    const baseEpoch = Math.max(...committedEpochs);
    let fileEpoch = 0;
    const existingFile = readIf(directoryFile);
    if (existingFile !== null) {
      try {
        fileEpoch = Number(JSON.parse(existingFile).directoryEpoch) || 0;
      } catch {
        fileEpoch = 0;
      }
    }
    const baseDigests = new Set(charters.views.map(({ view }) => view.directoryDigest || ''));
    const baseDigest = baseEpoch > 0 ? [...baseDigests][0] : '';
    if (baseEpoch > 0) {
      assert('pre-directory-namespace-refused', {
        expected: '400 namespace_requires_federation (wA into nsA2 before any directory)', kind: 'diagnostic',
        note: `directory epoch ${baseEpoch} already committed: start with --fresh to cover the unfederated rule`, observed: 'not run', ok: null,
      });
    } else {
      const leaderA = await leaderOf(A);
      const form = buildWrite({ key: wallets.wA.privateKey, message: `[fed smoke ${nonce}] wA into nsA2 before directory`, namespace: addr.nsA2 });
      const response = await submit('P1 wA->nsA2 unfederated', A, leaderA, form);
      assert('pre-directory-namespace-refused', { evidence: `requests.ndjson#${response.seq}`, expected: '400 namespace_requires_federation', observed: observedOf(response), ok: expectStatus(response, 400, 'namespace_requires_federation') });
    }

    // ── P2 directory epoch E1 ─────────────────────────────────────────────────────────────────
    phase = 'P2';
    const e1 = Math.max(baseEpoch, fileEpoch) + 1;
    log(`━━ P2 directory epoch ${e1}`);
    const writeDirectory = (document) => {
      const tmp = `${directoryFile}.tmp-${process.pid}`;
      writeFileSync(tmp, `${JSON.stringify(document, null, 2)}\n`);
      renameSync(tmp, directoryFile);
      write(`directory-epoch-${document.directoryEpoch}.json`, document);
    };
    const doc1 = directoryDocument({ clusters, epoch: e1, wallets: addr, writersA: [addr.wA] });
    writeDirectory(doc1);
    const converge = async (epoch) => waitFor(`directory epoch ${epoch} on all members`, async () => {
      const views = await federationViews(`directory ${epoch}`);
      const digests = new Set(views.map(({ view }) => view.directoryDigest));
      return {
        digests,
        done: views.every(({ view }) => Number(view.status?.directoryEpoch) === epoch && Number(view.directory?.directoryEpoch) === epoch)
          && digests.size === 1 && !digests.has(undefined) && !digests.has(''),
        views,
      };
    });
    const c1 = await converge(e1);
    const p2 = await snapshot(`P2-directory-${e1}`);
    const e1Digest = [...c1.digests][0];
    directoryDigests[e1] = e1Digest;
    assert('directory-converged', { evidence: p2, expected: `all 6 members at epoch ${e1} with one directoryDigest within ${opts.deadlineMs} ms`, observed: c1.views.map(({ member, view }) => `${member.cluster.label}${member.index}:${view.status?.directoryEpoch}/${short(view.directoryDigest)}`), ok: c1.ok, note: c1.ok ? `${c1.waitedMs} ms` : '' });
    if (!c1.ok) {
      assert('directory-source-error', { evidence: p2, expected: 'no sourceError', kind: 'diagnostic', observed: c1.views.map(({ view }) => view.status?.sourceError ?? null), ok: c1.views.every(({ view }) => !view.status?.sourceError) });
      throw new Abort(`directory epoch ${e1} did not converge`);
    }
    const committedDir = c1.views[0].view.directory ?? {};
    const entryFor = (directory, id) => (directory?.entries ?? []).find((entry) => String(entry.enterpriseId).toLowerCase() === id);
    const contentMatches = (directory, document) => document.entries.every((expected) => {
      const actual = entryFor(directory, expected.enterpriseId);
      return actual && actual.status === 'ACTIVE' && sameList(actual.namespaces, expected.namespaces)
        && sameList(actual.writers, expected.writers) && JSON.stringify(actual.endpoints) === JSON.stringify(expected.endpoints);
    }) && (directory?.entries ?? []).length === document.entries.length;
    assert('directory-content', { evidence: p2, expected: doc1.entries, observed: committedDir.entries, ok: contentMatches(committedDir, doc1) });
    assert('directory-prev-digest', { evidence: p2, expected: baseDigest || '(empty: first directory)', observed: [...new Set(c1.views.map(({ view }) => view.directory?.prevDigest ?? null))], ok: c1.views.every(({ view }) => (view.directory?.prevDigest ?? '') === baseDigest) });
    for (const cluster of clusters) {
      const views = c1.views.filter(({ member }) => member.cluster === cluster);
      const expectedNs = cluster === A ? [addr.nsA1, addr.nsA2] : [addr.nsB1];
      assert(`federated-${cluster.label}`, {
        evidence: p2, expected: `federated=true localStatus=ACTIVE localNamespaces=${expectedNs.map(short).join(',')}`,
        observed: views.map(({ view }) => `${view.status?.federated}/${view.status?.localStatus}/${(view.status?.localNamespaces ?? []).map(short).join(',')}`),
        ok: views.every(({ view }) => view.status?.federated === true && view.status?.localStatus === 'ACTIVE' && sameList(view.status?.localNamespaces, expectedNs)),
      });
    }
    assert('no-source-error', { evidence: p2, expected: 'no member reports a sourceError', kind: 'diagnostic', observed: c1.views.map(({ view }) => view.status?.sourceError ?? null), ok: c1.views.every(({ view }) => !view.status?.sourceError) });

    // ── P3 writes and deletes ─────────────────────────────────────────────────────────────────
    phase = 'P3';
    log('━━ P3 writes');
    const message = (what) => `[fed smoke ${nonce}] ${what}`;
    const accepted = async (id, label, cluster, form, namespace) => {
      const leader = await leaderOf(cluster);
      const response = await submit(label, cluster, leader, form);
      const ok = assert(`${id}-accepted`, { evidence: `requests.ndjson#${response.seq}`, expected: '202', observed: observedOf(response), ok: response.status === 202 });
      const storagePath = response.json?.storagePath ?? '';
      assert(`${id}-storage-path`, { evidence: `requests.ndjson#${response.seq}`, expected: `${namespaceRoot(namespace)}/…`, observed: storagePath, ok: storagePath.startsWith(`${namespaceRoot(namespace)}/`) });
      if (!ok) return { response, storagePath };
      const done = await committed(id, cluster, form.proposalId);
      assert(`${id}-committed`, { evidence: `requests.ndjson#${done.seq}`, expected: 'COMMITTED', observed: done.verdict?.outcome ?? done.state, ok: done.verdict ? done.verdict.outcome === 'COMMITTED' : false });
      const visible = await contentOn(`${id} visible`, cluster.members, namespace, form.message);
      assert(`${id}-visible-${cluster.label}`, { evidence: Object.values(visible.seen).map((s) => `requests.ndjson#${s.seq}`).join(','), expected: `message on all ${cluster.members.length} members of cluster ${cluster.label}`, observed: Object.fromEntries(Object.entries(visible.seen).map(([url, s]) => [url, s.found])), ok: visible.ok });
      return { response, storagePath };
    };

    const w1Form = buildWrite({ key: wallets.nsA1.privateKey, message: message('nsA1 own write on A') });
    const w1 = await accepted('w1-nsA1-on-A', 'P3 nsA1 -> A leader', A, w1Form, addr.nsA1);
    const w2Form = buildWrite({ key: wallets.nsB1.privateKey, message: message('nsB1 own write on B') });
    const w2 = await accepted('w2-nsB1-on-B', 'P3 nsB1 -> B leader', B, w2Form, addr.nsB1);

    const bEndpoint = `${B.members[0].url}/v1/propose-write`;
    const w3 = await submit('P3 nsB1 -> A (wrong cluster)', A, A.members[0], buildWrite({ key: wallets.nsB1.privateKey, message: message('nsB1 sent to A') }), '/v1/propose-write', { follow: false });
    assert('w3-nsB1-on-A-redirect', { evidence: `requests.ndjson#${w3.seq}`, expected: `307 wrong_cluster Location=${bEndpoint}`, observed: `${observedOf(w3)} Location=${w3.location}`, ok: expectStatus(w3, 307, 'wrong_cluster') && w3.location === bEndpoint });
    assert('w3-redirect-body', { evidence: `requests.ndjson#${w3.seq}`, expected: { endpoints: B.members.map((m) => m.url), enterpriseId: B.enterpriseId }, observed: { endpoints: w3.json?.endpoints, enterpriseId: w3.json?.enterpriseId }, ok: w3.json?.enterpriseId === B.enterpriseId && JSON.stringify(w3.json?.endpoints) === JSON.stringify(B.members.map((m) => m.url)) });

    const w4Form = buildWrite({ key: wallets.wA.privateKey, message: message('wA writes into nsA2'), namespace: addr.nsA2 });
    const w4 = await accepted('w4-wA-into-nsA2', 'P3 wA -> nsA2', A, w4Form, addr.nsA2);
    if (w4.response.status === 202) {
      const walletPath = namespaceRoot(addr.nsA2);
      const walletProps = [];
      for (const member of A.members) {
        const nav = await call(`P3 explorer nav ${member.url}`, 'GET', `${member.url}/v1/explorer/content/nav`);
        const clusterId = nav.json?.localCluster?.clusterId;
        if (!clusterId) {
          walletProps.push({ member: member.url, seq: nav.seq, wallet: null });
          continue;
        }
        const node = await call(`P3 explorer wallet node ${member.url}`, 'GET', `${member.url}/v1/explorer/content/clusters/${encodeURIComponent(clusterId)}/node?path=${encodeURIComponent(walletPath)}`);
        const prop = (node.json?.properties ?? []).find((p) => p.name === 'wallet');
        walletProps.push({ member: member.url, seq: node.seq, wallet: prop?.value ?? null });
        if (member === A.members[0] && w4.storagePath) {
          const content = await call(`P3 explorer content node ${member.url}`, 'GET', `${member.url}/v1/explorer/content/clusters/${encodeURIComponent(clusterId)}/node?path=${encodeURIComponent(w4.storagePath)}`);
          const signer = (content.json?.properties ?? []).find((p) => p.name === 'wallet')?.value ?? null;
          assert('w4-content-signer', { evidence: `requests.ndjson#${content.seq}`, expected: `content node wallet = signer ${addr.wA}`, kind: 'diagnostic', observed: signer, ok: signer === null ? null : signer === addr.wA });
        }
      }
      assert('w4-wallet-node-is-namespace', { evidence: walletProps.map((p) => `requests.ndjson#${p.seq}`).join(','), expected: `wallet property of ${walletPath} = ${addr.nsA2} on all A members`, observed: walletProps.map((p) => p.wallet), ok: walletProps.every((p) => p.wallet === addr.nsA2) ? true : walletProps.some((p) => p.wallet && p.wallet !== addr.nsA2) ? false : null });
    }

    const leaderA = await leaderOf(A);
    const w5 = await submit('P3 stranger -> nsA1', A, leaderA, buildWrite({ key: wallets.stranger.privateKey, message: message('stranger into nsA1'), namespace: addr.nsA1 }));
    assert('w5-stranger-not-writer', { evidence: `requests.ndjson#${w5.seq}`, expected: '403 writer_not_authorized', observed: observedOf(w5), ok: expectStatus(w5, 403, 'writer_not_authorized') });
    const w6 = await submit('P3 unclaimed own namespace', A, leaderA, buildWrite({ key: wallets.unclaimed.privateKey, message: message('unclaimed namespace') }));
    assert('w6-unclaimed-namespace', { evidence: `requests.ndjson#${w6.seq}`, expected: '403 namespace_unclaimed', observed: observedOf(w6), ok: expectStatus(w6, 403, 'namespace_unclaimed') });

    if (w1.storagePath) {
      const d1 = await submit('P3 stranger deletes nsA1 content', A, leaderA, buildDelete({ contentPath: w1.storagePath, key: wallets.stranger.privateKey, namespace: addr.nsA1 }), '/v1/propose-delete');
      assert('d1-stranger-delete-refused', { evidence: `requests.ndjson#${d1.seq}`, expected: '403 writer_not_authorized', observed: observedOf(d1), ok: expectStatus(d1, 403, 'writer_not_authorized') });
    }
    if (w2.storagePath) {
      const bDelete = `${B.members[0].url}/v1/propose-delete`;
      const d2 = await submit('P3 nsB1 delete sent to A', A, A.members[0], buildDelete({ contentPath: w2.storagePath, key: wallets.nsB1.privateKey }), '/v1/propose-delete', { follow: false });
      assert('d2-delete-wrong-cluster', { evidence: `requests.ndjson#${d2.seq}`, expected: `307 wrong_cluster Location=${bDelete}`, observed: `${observedOf(d2)} Location=${d2.location}`, ok: expectStatus(d2, 307, 'wrong_cluster') && d2.location === bDelete });
    }
    await snapshot('P3-writes');

    // ── P4 cross-cluster reads through the directory mounts ──────────────────────────────────
    phase = 'P4';
    log('━━ P4 cross-cluster reads');
    const mounts = await waitFor('directory mounts verified and available', async () => {
      const rows = [];
      for (const member of allMembers) {
        const other = member.cluster === A ? B : A;
        const response = await call(`P4 health ${member.cluster.label}${member.index}`, 'GET', `${member.url}/health`);
        const sharding = response.json?.sharding ?? {};
        const mount = (sharding.remoteMounts ?? []).find((m) => String(m.enterpriseId ?? '').toLowerCase() === other.enterpriseId);
        rows.push({ available: mount?.available === true, member, mount, mountSource: sharding.mountSource, seq: response.seq, verified: mount?.verified === true });
      }
      return { done: rows.every((row) => row.mountSource === 'directory' && row.verified && row.available), rows };
    });
    const p4 = await snapshot('P4-reads');
    for (const cluster of clusters) {
      const rows = mounts.rows.filter((row) => row.member.cluster === cluster);
      const other = cluster === A ? B : A;
      const otherNs = other === A ? [addr.nsA1, addr.nsA2] : [addr.nsB1];
      assert(`mount-source-${cluster.label}`, { evidence: p4, expected: 'sharding.mountSource=directory on 3 members', observed: rows.map((row) => row.mountSource), ok: rows.every((row) => row.mountSource === 'directory') });
      assert(`mount-verified-${cluster.label}`, { evidence: p4, expected: `mount of enterprise ${short(other.enterpriseId)} verified=true available=true on 3 members`, observed: rows.map((row) => `${row.verified}/${row.available}`), ok: rows.every((row) => row.verified && row.available) });
      assert(`mount-namespaces-${cluster.label}`, { evidence: p4, expected: otherNs, observed: rows.map((row) => row.mount?.namespaces ?? null), ok: rows.every((row) => sameList(row.mount?.namespaces, otherNs)) });
      assert(`mount-epoch-${cluster.label}`, { evidence: p4, expected: e1, kind: 'diagnostic', observed: rows.map((row) => row.mount?.directoryEpoch ?? null), ok: rows.every((row) => Number(row.mount?.directoryEpoch) === e1) });
    }
    if (!mounts.ok) throw new Abort('directory mounts did not become verified and available');
    const readAcross = async (id, readers, namespace, text) => {
      const seen = await contentOn(`P4 ${id}`, readers, namespace, text, { remote: true });
      const unavailable = stats.allowed5xx.filter((row) => row.label.startsWith(`P4 ${id}`)).length;
      assert(id, { evidence: Object.values(seen.seen).map((s) => `requests.ndjson#${s.seq}`).join(','), expected: 'committed message readable on every member of the other cluster', observed: Object.fromEntries(Object.entries(seen.seen).map(([url, s]) => [url, s.found ? 'found' : `missing (http ${s.status})`])), ok: seen.ok, note: unavailable ? `${unavailable} 503 answer(s) while the mount was unavailable` : '' });
    };
    if (w1.response.status === 202) await readAcross('b-reads-nsA1', B.members, addr.nsA1, w1Form.message);
    if (w2.response.status === 202) await readAcross('a-reads-nsB1', A.members, addr.nsB1, w2Form.message);
    if (w4.response.status === 202) await readAcross('b-reads-nsA2', B.members, addr.nsA2, w4Form.message);

    // ── P5 directory epoch E2: wA removed ─────────────────────────────────────────────────────
    phase = 'P5';
    const e2 = e1 + 1;
    log(`━━ P5 directory epoch ${e2} (wA removed)`);
    const doc2 = directoryDocument({ clusters, epoch: e2, wallets: addr, writersA: [] });
    writeDirectory(doc2);
    const c2 = await converge(e2);
    const p5 = await snapshot(`P5-directory-${e2}`);
    directoryDigests[e2] = [...c2.digests][0];
    assert('directory-converged', { evidence: p5, expected: `all 6 members at epoch ${e2} with one directoryDigest within ${opts.deadlineMs} ms`, observed: c2.views.map(({ member, view }) => `${member.cluster.label}${member.index}:${view.status?.directoryEpoch}/${short(view.directoryDigest)}`), ok: c2.ok, note: c2.ok ? `${c2.waitedMs} ms` : '' });
    if (!c2.ok) throw new Abort(`directory epoch ${e2} did not converge`);
    assert('directory-prev-digest', { evidence: p5, expected: e1Digest, observed: [...new Set(c2.views.map(({ view }) => view.directory?.prevDigest ?? null))], ok: c2.views.every(({ view }) => view.directory?.prevDigest === e1Digest) });
    assert('directory-content', { evidence: p5, expected: doc2.entries, observed: c2.views[0].view.directory?.entries, ok: contentMatches(c2.views[0].view.directory, doc2) });
    const w7 = await submit('P5 wA -> nsA2 after removal', A, await leaderOf(A), buildWrite({ key: wallets.wA.privateKey, message: message('wA into nsA2 after removal'), namespace: addr.nsA2 }));
    assert('w7-removed-writer-refused', { evidence: `requests.ndjson#${w7.seq}`, expected: '403 writer_not_authorized', observed: observedOf(w7), ok: expectStatus(w7, 403, 'writer_not_authorized') });
    const mounts2 = await waitFor(`mounts at epoch ${e2}`, async () => {
      const epochs = [];
      for (const member of allMembers) {
        const response = await call(`P5 health ${member.cluster.label}${member.index}`, 'GET', `${member.url}/health`);
        epochs.push(Number(response.json?.sharding?.directoryEpoch));
      }
      return { done: epochs.every((epoch) => epoch === e2), epochs };
    });
    assert('mounts-follow-epoch', { evidence: p5, expected: `/health sharding.directoryEpoch=${e2} on all 6`, kind: 'diagnostic', observed: mounts2.epochs, ok: mounts2.ok });

    // ── P6 end state ──────────────────────────────────────────────────────────────────────────
    phase = 'P6';
    log('━━ P6 end state');
    const p6 = await snapshot('P6-end');
    const health = [];
    for (const member of allMembers) {
      const local = await call(`P6 health/local ${member.cluster.label}${member.index}`, 'GET', `${member.url}/health/local`);
      health.push({ code: local.status, member });
    }
    assert('members-healthy', { evidence: p6, expected: 'all 6 members answer /health/local 200', observed: health.map((h) => `${h.member.cluster.label}${h.member.index}:${h.code}`), ok: health.every((h) => h.code === 200) });
    const pidsNow = memberFacts.map((fact) => {
      const cluster = clusters.find((c) => c.label === fact.cluster);
      return (readIf(path.join(cluster.pidDir ?? '', `validator-${fact.index}.pid`)) ?? '').trim() || null;
    });
    assert('no-restarts', { expected: 'the pid of every member is unchanged', observed: pidsNow, ok: memberFacts.every((fact) => fact.pid) ? memberFacts.every((fact, i) => fact.pid === pidsNow[i]) : null });
  } catch (error) {
    if (!(error instanceof Abort)) throw error;
    aborted = error.message;
    log(`🛑 Aborted in ${phase}: ${aborted}`);
    assertions.push({ assertionId: 'aborted', evidence: 'requests.ndjson', expected: 'no abort', kind: 'required', note: 'clusters left running for inspection', observed: aborted, scenarioId: phase, status: STATUS.FAIL });
    try {
      await snapshot(`abort-${phase}`, true);
    } catch {
      // the abort snapshot is best effort
    }
  }

  // Unexpected 5xx and validator log ERRORs over the whole run (also after an abort).
  const endPhase = phase;
  phase = 'P6';
  assertions.push({
    assertionId: 'no-unexpected-5xx', evidence: 'requests.ndjson', expected: 'no 5xx except no_quorum retries and 503 from an unavailable mount',
    kind: 'required', note: stats.allowed5xx.length ? `${stats.allowed5xx.length} tolerated: ${JSON.stringify(stats.allowed5xx).slice(0, 300)}` : '',
    observed: stats.unexpected5xx, scenarioId: phase, status: stats.unexpected5xx.length === 0 ? STATUS.PASS : STATUS.FAIL,
  });
  const scan = memberFacts.map((fact) => {
    const text = fact.logFile ? readFrom(fact.logFile, fact.logOffset) : null;
    if (text === null) return { ...fact, errorLines: null, federationErrors: null, sample: [] };
    const errors = text.split('\n').filter((line) => /\bERROR\b/.test(line));
    const federation = errors.filter((line) => /federat|directory|charter|namespace|enterprise|mount/i.test(line));
    return { cluster: fact.cluster, errorLines: errors.length, federationErrors: federation.length, index: fact.index, logFile: fact.logFile, sample: federation.slice(0, 20) };
  });
  write('log-scan.json', scan);
  const scanned = scan.every((row) => row.federationErrors !== null);
  assertions.push({
    assertionId: 'no-federation-errors-in-logs', evidence: 'log-scan.json', expected: 'no ERROR-level federation lines appended to any validator log during the run', kind: 'required',
    note: `ERROR lines (all kinds): ${scan.map((row) => `${row.cluster}${row.index}=${row.errorLines ?? '?'}`).join(' ')}`,
    observed: scan.map((row) => `${row.cluster}${row.index}=${row.federationErrors ?? '?'}`).join(' '),
    scenarioId: phase, status: !scanned ? STATUS.UNKNOWN : scan.every((row) => row.federationErrors === 0) ? STATUS.PASS : STATUS.FAIL,
  });

  const result = summarize(assertions);
  const summary = {
    aborted, abortedInPhase: aborted ? endPhase : null, directoryDigests, endedAt: now().toISOString(), evidenceDir: dir,
    requests: stats.requests, startedAt: startedAt.toISOString(), writeRequests: stats.writes, ...result,
  };
  const header = 'phase\tassertionId\tkind\texpected\tobserved\tstatus\tevidence\tnote';
  const rows = assertions.map((row) => [row.scenarioId, row.assertionId, row.kind, row.expected, row.observed, row.status, row.evidence, row.note].map(cell).join('\t'));
  write('assertions.tsv', `${[header, ...rows].join('\n')}\n`);
  write('summary.json', summary);
  write('report.md', [
    `# Federation 3x2 smoke — ${summary.status}`,
    '',
    `- Evidence: \`${dir}\``,
    `- Jar: \`${manifest.jar.path ?? 'unknown'}\` (sha256 ${manifest.jar.sha256 ?? 'unknown'})`,
    `- Required: ${result.required.pass} pass, ${result.required.fail} fail, ${result.required.unknown} unknown (of ${result.required.total})`,
    `- Requests: ${stats.requests} (writes/deletes: ${stats.writes})${aborted ? `\n- Aborted in ${endPhase}: ${aborted}` : ''}`,
    '',
    '| Phase | Assertion | Kind | Status | Observed |',
    '|---|---|---|---|---|',
    ...assertions.map((row) => `| ${row.scenarioId} | ${row.assertionId} | ${row.kind} | **${row.status}** | ${cell(row.observed).replace(/\|/g, '\\|').slice(0, 160)} |`),
    '',
  ].join('\n'));
  if (seal) sealEvidence(dir);
  log(`${summary.status === STATUS.PASS ? '✅' : '❌'} Federation 3x2 smoke ${summary.status}: ${result.required.pass}/${result.required.total} required PASS, ${result.required.fail} FAIL, ${result.required.unknown} UNKNOWN`);
  log(`   Evidence: ${dir}`);
  return summary;
}

// CLI: the shell entry point passes the resolved topology as FED_SMOKE_CONFIG (JSON).
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  let config;
  try {
    config = JSON.parse(process.env.FED_SMOKE_CONFIG ?? '');
  } catch {
    process.stderr.write('FED_SMOKE_CONFIG must hold the topology JSON (run tests/routing/federation-3x2-smoke.sh)\n');
    process.exit(2);
  }
  const seconds = Number(process.env.FED_SMOKE_DEADLINE_SECONDS || 0);
  const pollMs = Number(process.env.FED_SMOKE_POLL_MS || 0);
  config.options = {
    ...(seconds > 0 ? { deadlineMs: seconds * 1000 } : {}),
    ...(pollMs > 0 ? { pollMs } : {}),
  };
  runFederationSmoke(config).then(
    (summary) => process.exit(summary.status === STATUS.PASS ? 0 : 1),
    (error) => {
      process.stderr.write(`❌ ${error.message}\n`);
      process.exit(2);
    },
  );
}
