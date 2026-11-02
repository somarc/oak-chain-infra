// Shared evidence session for the enterprise-federation 3x2 live scenarios (federation-smoke.mjs,
// federation-failover.mjs, federation-gc.mjs). One session owns one immutable evidence directory under
// $FED_3X2_ROOT/evidence/ and records every request it makes:
//
//     manifest.json        provenance: git SHAs and dirty state, jar path + sha256, java -version,
//                          ports, PIDs with exact command lines, launch records, log offsets
//     requests.ndjson      every request/response (status, headers incl. Location, body)
//     snapshots/<phase>/   GET /v1/federation and /health of the members per phase
//     log-scan.json        ERROR lines appended to the validator logs during the run
//     assertions.tsv       phase | assertionId | kind | expected | observed | status | evidence | note
//     summary.json, report.md
//
// Every wait has a deadline. A member that stops answering or an unexpected 5xx throws Abort; the
// scenario records it and finish() still writes and seals the evidence.

import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import {
  appendFileSync, chmodSync, closeSync, existsSync, mkdirSync, openSync, readFileSync, readSync, readdirSync,
  realpathSync, statSync, writeFileSync,
} from 'node:fs';
import path from 'node:path';

import { classifyOperation } from './harness/client.mjs';
import { STATUS, summarize } from './harness/evidence.mjs';
import { testKey } from './tx.mjs';

export { STATUS };

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

export class Abort extends Error {}

export const sleepDefault = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

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

// Shard levels of an address (WalletPathUtil): the first three bytes of the address.
export function namespaceRoot(address) {
  const hex = address.slice(2);
  return `/oak-chain/${hex.slice(0, 2)}/${hex.slice(2, 4)}/${hex.slice(4, 6)}/${address}`;
}

export const sorted = (values) => [...(values ?? [])].map(String).sort();
export const sameList = (left, right) => JSON.stringify(sorted(left)) === JSON.stringify(sorted(right));
export const short = (value) => (typeof value === 'string' && value.length > 18 ? `${value.slice(0, 12)}…` : value);

export function sha256File(file) {
  const hash = createHash('sha256');
  hash.update(readFileSync(file));
  return hash.digest('hex');
}

export function defaultExec(command, args, { cwd } = {}) {
  const result = spawnSync(command, args, { cwd, encoding: 'utf8', timeout: 15_000 });
  return { code: result.status, stderr: result.stderr ?? '', stdout: result.stdout ?? '', error: result.error?.message ?? null };
}

export function gitState(exec, dir) {
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

export function parseRecord(text) {
  const out = {};
  for (const line of String(text ?? '').split('\n')) {
    if (!line || line.startsWith('#') || !line.includes('=')) continue;
    out[line.slice(0, line.indexOf('='))] = line.slice(line.indexOf('=') + 1);
  }
  return out;
}

export function readIf(file) {
  try {
    return readFileSync(file, 'utf8');
  } catch {
    return null;
  }
}

export function fileSize(file) {
  try {
    return statSync(file).size;
  } catch {
    return null;
  }
}

export function readFrom(file, offset) {
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

export function sealEvidence(dir) {
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) sealEvidence(full);
    else chmodSync(full, 0o444);
  }
  chmodSync(dir, 0o555);
}

// requests.ndjson keeps every request, but not megabytes of test payload: strings longer than
// `max` characters are recorded as their length and sha256 (the scenario keeps the full values).
export function compactValue(value, max = 1024) {
  if (typeof value === 'string') {
    return value.length > max ? `<${value.length} chars sha256:${createHash('sha256').update(value).digest('hex')}>` : value;
  }
  if (Array.isArray(value)) return value.map((item) => compactValue(item, max));
  if (value && typeof value === 'object') return Object.fromEntries(Object.entries(value).map(([key, item]) => [key, compactValue(item, max)]));
  return value;
}

export function cell(value) {
  if (value === undefined || value === null) return '';
  const text = typeof value === 'string' ? value : JSON.stringify(value);
  return text.replace(/[\t\r\n]+/g, ' ');
}


// Opens the evidence directory `$fedRoot/evidence/<dirName>` and returns the request, wait, snapshot
// and write helpers bound to it. Throws before any action when the topology is not root-bound.
export function createFederationSession(config, {
  env = process.env,
  exec = defaultExec,
  fetchImpl = globalThis.fetch,
  log = (line) => process.stdout.write(`${line}\n`),
  now = () => new Date(),
  sleep = sleepDefault,
} = {}, { dirName = (stamp) => stamp, initialPhase = 'P0', scenario = 'federation smoke', title = 'Federation 3x2 smoke' } = {}) {
  const opts = { ...DEFAULTS, ...config.options };
  const problem = federationRootProblem(config.fedRoot, { home: env.HOME, protectedRoots: env.OAK_PROTECTED_ROOTS });
  if (problem) throw new Error(`Refusing ${scenario}: ${problem}`);
  if (!Array.isArray(config.clusters) || config.clusters.length !== 2) throw new Error('config.clusters must hold cluster A and cluster B');
  for (const cluster of config.clusters) {
    const expectedRoot = path.join(config.fedRoot, `cluster-${cluster.label}`);
    if (cluster.runtimeRoot && path.resolve(cluster.runtimeRoot) !== expectedRoot) {
      throw new Error(`Refusing ${scenario}: cluster ${cluster.label} runtime root ${cluster.runtimeRoot} is not ${expectedRoot}`);
    }
  }
  const directoryFile = config.directoryFile ?? path.join(config.fedRoot, 'directory.json');
  if (path.dirname(path.resolve(directoryFile)) !== path.resolve(config.fedRoot)) {
    throw new Error(`Refusing ${scenario}: directory file ${directoryFile} is not directly under ${config.fedRoot}`);
  }

  const startedAt = now();
  const evidenceRoot = path.join(config.fedRoot, 'evidence');
  mkdirSync(evidenceRoot, { recursive: true });
  const dir = path.join(evidenceRoot, dirName(utcStamp(startedAt)));
  mkdirSync(dir); // throws EEXIST: an evidence directory is never reused
  mkdirSync(path.join(dir, 'snapshots'));

  const clusters = config.clusters.map((cluster) => ({ ...cluster, members: clusterMembers(cluster) }));
  const allMembers = clusters.flatMap((cluster) => cluster.members.map((member) => ({ ...member, cluster })));
  const wallets = Object.fromEntries(Object.entries(WALLET_ROLES).map(([role, index]) => [role, testKey(index)]));
  const addr = Object.fromEntries(Object.entries(wallets).map(([role, key]) => [role, key.address]));
  const nonce = `${utcStamp(startedAt)}-${process.pid}`;
  const assertions = [];
  const stats = { allowed5xx: [], requests: 0, unexpected5xx: [], writes: 0 };
  let seq = 0;
  const s = {
    addr, allMembers, assertions, clusters, dir, directoryFile, nonce, opts, phase: initialPhase, stats, wallets,
    A: clusters[0], B: clusters[1],
  };
  const label = (member) => `${member.cluster?.label ?? ''}${member.index}`;

  s.write = (name, value) => writeFileSync(path.join(dir, name), typeof value === 'string' ? value : `${JSON.stringify(value, null, 2)}\n`);
  s.assert = (id, { evidence = '', expected, kind = 'required', note = '', observed, ok }) => {
    const status = ok === true ? STATUS.PASS : ok === false ? STATUS.FAIL : STATUS.UNKNOWN;
    assertions.push({ assertionId: id, evidence, expected, kind, note, observed, scenarioId: s.phase, status });
    log(`  ${status === STATUS.PASS ? '✅' : status === STATUS.FAIL ? '❌' : '❔'} ${s.phase} ${id}: ${cell(observed).slice(0, 160)}`);
    return status === STATUS.PASS;
  };
  s.log = log;

  // Every request goes through here: recorded (strings over 1 KiB as length + sha256, see
  // compactValue), then classified. `tolerate` records without aborting (for members that are
  // expected to be down or still starting). `files` ([{ field, name, type, bytes }]) sends the form
  // as multipart/form-data with those file parts; `binary` reads a 200 response as bytes
  // (result.bytes; recorded as length + sha256).
  s.call = async (callLabel, method, url, { allow5xx = () => false, binary = false, files = null, form = null, tolerate = false } = {}) => {
    seq += 1;
    stats.requests += 1;
    const id = seq;
    const at = new Date().toISOString();
    const started = Date.now();
    const headers = {};
    let status = 0;
    let text = '';
    let bytes = null;
    let error = null;
    let body;
    let requestHeaders = { Accept: 'application/json' };
    if (files) {
      body = new FormData();
      for (const [key, value] of Object.entries(form ?? {})) body.append(key, value);
      for (const file of files) body.append(file.field ?? 'file', new Blob([file.bytes], { type: file.type ?? 'application/octet-stream' }), file.name);
    } else if (form) {
      body = new URLSearchParams(form).toString();
      requestHeaders = { ...requestHeaders, 'Content-Type': 'application/x-www-form-urlencoded' };
    }
    try {
      const response = await fetchImpl(url, {
        body,
        headers: requestHeaders,
        method,
        redirect: 'manual',
        signal: AbortSignal.timeout(opts.requestTimeoutMs),
      });
      status = response.status;
      response.headers.forEach((value, key) => { headers[key] = value; });
      if (binary && status === 200) bytes = Buffer.from(await response.arrayBuffer());
      else text = await response.text();
    } catch (caught) {
      error = caught instanceof Error ? caught.message : String(caught);
    }
    let json = null;
    try {
      json = text ? JSON.parse(text) : null;
    } catch {
      json = null;
    }
    const recordedBody = bytes ? { bytes: bytes.length, sha256: createHash('sha256').update(bytes).digest('hex') }
      : compactValue(json ?? text);
    const recordedFiles = files ? files.map((file) => ({ bytes: file.bytes.length, field: file.field ?? 'file', name: file.name, sha256: createHash('sha256').update(file.bytes).digest('hex'), type: file.type ?? null })) : undefined;
    const record = {
      at, body: recordedBody, durationMs: Date.now() - started, error, files: recordedFiles, headers, label: callLabel, location: headers.location ?? null,
      method, phase: s.phase, request: compactValue(form), seq: id, status, url,
    };
    appendFileSync(path.join(dir, 'requests.ndjson'), `${JSON.stringify(record)}\n`);
    const result = { at, bytes, error, headers, json, location: headers.location ?? null, seq: id, status, text, url };
    if (tolerate) return result;
    if (status === 0) throw new Abort(`member down: ${method} ${url} did not answer (${error}) [requests.ndjson#${id}]`);
    if (status >= 500) {
      if (allow5xx(status, json)) {
        stats.allowed5xx.push({ code: json?.code ?? null, label: callLabel, phase: s.phase, seq: id, status });
      } else {
        stats.unexpected5xx.push({ label: callLabel, seq: id, status });
        throw new Abort(`unexpected HTTP ${status} from ${callLabel} (${method} ${url}) [requests.ndjson#${id}]`);
      }
    }
    return result;
  };

  s.waitFor = async (what, probe, { deadlineMs = opts.deadlineMs, pollMs = opts.pollMs } = {}) => {
    const started = Date.now();
    const deadline = started + deadlineMs;
    let last;
    for (;;) {
      last = await probe();
      if (last.done) return { ...last, ok: true, waitedMs: Date.now() - started };
      if (Date.now() >= deadline) {
        log(`  ⏱  ${what}: deadline (${deadlineMs} ms) reached`);
        return { ...last, ok: false, waitedMs: Date.now() - started };
      }
      await sleep(pollMs);
    }
  };

  // GET /v1/federation of every member; `tolerateMember` members are recorded but may be down.
  s.federationViews = async (viewLabel, { members = allMembers, tolerateMember = () => false } = {}) => {
    const views = [];
    for (const member of members) {
      const response = await s.call(`${viewLabel} ${label(member)}`, 'GET', `${member.url}/v1/federation`, { tolerate: tolerateMember(member) });
      views.push({ member, response, view: response.json ?? {} });
    }
    return views;
  };

  s.snapshot = async (name, tolerate = false, { tolerateMember = () => false } = {}) => {
    const target = path.join(dir, 'snapshots', name);
    mkdirSync(target, { recursive: true });
    for (const member of allMembers) {
      for (const [kind, route] of [['federation', '/v1/federation'], ['health', '/health']]) {
        const response = await s.call(`snapshot ${name} ${label(member)} ${kind}`, 'GET', `${member.url}${route}`, { tolerate: tolerate || tolerateMember(member) });
        writeFileSync(path.join(target, `${label(member)}-${kind}.json`),
          `${JSON.stringify({ body: response.json ?? response.text, seq: response.seq, status: response.status, url: response.url }, null, 2)}\n`);
      }
    }
    return `snapshots/${name}`;
  };

  // Exactly one LEADER among `members` (default: the whole cluster) within the deadline.
  s.leaderOf = async (cluster, { deadlineMs = opts.deadlineMs, members = cluster.members } = {}) => {
    const found = await s.waitFor(`leader of cluster ${cluster.label}`, async () => {
      const leaders = [];
      for (const member of members) {
        const response = await s.call(`leader probe ${cluster.label}${member.index}`, 'GET', `${member.url}/v1/consensus/status`);
        if (response.json?.currentRole === 'LEADER') leaders.push(member);
      }
      return { done: leaders.length === 1, leaders };
    }, { deadlineMs });
    if (!found.ok) throw new Abort(`cluster ${cluster.label} has ${found.leaders.length} leaders after ${deadlineMs} ms`);
    return found.leaders[0];
  };

  // POST a signed write or delete. Follows a leader redirect within the same cluster (never a
  // wrong_cluster redirect); retries no_quorum like the 3x2 smokes unless retryNoQuorum is false.
  s.submit = async (submitLabel, cluster, member, form, route = '/v1/propose-write', { files = null, follow = true, retryNoQuorum = true } = {}) => {
    let target = `${member.url}${route}`;
    let response;
    for (let attempt = 0; attempt < 6; attempt += 1) {
      stats.writes += 1;
      if (stats.writes > opts.maxWrites) throw new Abort(`write budget of ${opts.maxWrites} requests exhausted`);
      const noQuorum = (status, json) => retryNoQuorum && status === 503 && JSON.stringify(json ?? '').includes('no_quorum');
      response = await s.call(submitLabel, 'POST', target, { allow5xx: noQuorum, files, form });
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
  };

  s.committed = async (commitLabel, cluster, proposalId, { deadlineMs = opts.deadlineMs, members = cluster.members } = {}) => s.waitFor(`${commitLabel} committed`, async () => {
    const leader = await s.leaderOf(cluster, { deadlineMs, members });
    const response = await s.call(`${commitLabel} operation`, 'GET', `${leader.url}/v1/ops/operations/${proposalId}`);
    const verdict = response.status === 200 ? classifyOperation(response.json) : null;
    return { done: Boolean(verdict), seq: response.seq, state: response.json?.state ?? `http ${response.status}`, verdict };
  }, { deadlineMs });

  // Every message on every member's /v1/wallets/content for the namespace. `remote` tolerates the
  // 503 a remote mount answers while unavailable (recorded in stats.allowed5xx).
  s.contentOn = async (contentLabel, members, namespace, message, { deadlineMs = opts.deadlineMs, remote = false, tolerateDown = false } = {}) => {
    const messages = Array.isArray(message) ? message : [message];
    const seen = {};
    const result = await s.waitFor(contentLabel, async () => {
      for (const member of members) {
        if (seen[member.url]?.found) continue;
        const response = await s.call(`${contentLabel} ${member.url}`, 'GET', `${member.url}/v1/wallets/content?wallet=${namespace}`, {
          allow5xx: (status) => remote && status === 503,
          tolerate: tolerateDown,
        });
        const items = Array.isArray(response.json?.content) ? response.json.content : [];
        seen[member.url] = { found: response.status === 200 && messages.every((m) => items.some((item) => item.message === m)), seq: response.seq, status: response.status };
      }
      return { done: members.every((m) => seen[m.url]?.found), seen };
    }, { deadlineMs });
    return result;
  };

  s.expectStatus = (response, status, code) => response.status === status && (code === undefined || response.json?.code === code);
  s.observedOf = (response) => `${response.status} ${response.json?.code ?? ''}`.trim();

  // PID and command line of a member from its pid file (null when absent or not running).
  s.memberProcess = (cluster, index) => {
    const pid = (readIf(path.join(cluster.pidDir ?? '', `validator-${index}.pid`)) ?? '').trim() || null;
    const command = pid ? exec('ps', ['-p', pid, '-o', 'command=']).stdout.trim() || null : null;
    return { command, pid };
  };

  // ── manifest (before any mutation) ─────────────────────────────────────────────────────────
  const jarPath = env.OAK_CONSENSUS_JAR || null;
  const jarSourceDir = env.FED_JAR_SOURCE_DIR || (jarPath ? path.dirname(jarPath) : null);
  const memberFacts = [];
  for (const cluster of clusters) {
    cluster.launchRecord = parseRecord(readIf(path.join(cluster.pidDir ?? '', 'cluster-launch.env')));
    for (const member of cluster.members) {
      const { command, pid } = s.memberProcess(cluster, member.index);
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
    scenario,
    startedAt: startedAt.toISOString(),
    wallets: Object.fromEntries(Object.entries(wallets).map(([role, key]) => [role, { address: key.address, keyIndex: key.index }])),
  };
  s.memberFacts = memberFacts;
  s.manifest = manifest;
  s.write('manifest.json', manifest);
  log(`🧾 Evidence: ${dir}`);

  // Records an Abort as a failing assertion and takes a best-effort snapshot.
  s.recordAbort = async (error, note = 'clusters left running for inspection') => {
    log(`🛑 Aborted in ${s.phase}: ${error.message}`);
    assertions.push({ assertionId: 'aborted', evidence: 'requests.ndjson', expected: 'no abort', kind: 'required', note, observed: error.message, scenarioId: s.phase, status: STATUS.FAIL });
    try {
      await s.snapshot(`abort-${s.phase}`, true);
    } catch {
      // the abort snapshot is best effort
    }
    return error.message;
  };

  // Unexpected 5xx, the log scan, assertions.tsv, summary.json, report.md; then seals the directory.
  s.finish = ({ aborted = null, extraReport = [], extraSummary = {}, finalPhase, logScanKind = 'required', seal = true, tolerated5xx = 'no 5xx except no_quorum retries and 503 from an unavailable mount' } = {}) => {
    const endPhase = s.phase;
    s.phase = finalPhase ?? endPhase;
    assertions.push({
      assertionId: 'no-unexpected-5xx', evidence: 'requests.ndjson', expected: tolerated5xx,
      kind: 'required', note: stats.allowed5xx.length ? `${stats.allowed5xx.length} tolerated: ${JSON.stringify(stats.allowed5xx).slice(0, 300)}` : '',
      observed: stats.unexpected5xx, scenarioId: s.phase, status: stats.unexpected5xx.length === 0 ? STATUS.PASS : STATUS.FAIL,
    });
    const scan = memberFacts.map((fact) => {
      const text = fact.logFile ? readFrom(fact.logFile, fact.logOffset) : null;
      if (text === null) return { ...fact, errorLines: null, federationErrors: null, sample: [] };
      const errors = text.split('\n').filter((line) => /\bERROR\b/.test(line));
      const federation = errors.filter((line) => /federat|directory|charter|namespace|enterprise|mount/i.test(line));
      return { cluster: fact.cluster, errorLines: errors.length, federationErrors: federation.length, index: fact.index, logFile: fact.logFile, sample: federation.slice(0, 20) };
    });
    s.write('log-scan.json', scan);
    const scanned = scan.every((row) => row.federationErrors !== null);
    assertions.push({
      assertionId: 'no-federation-errors-in-logs', evidence: 'log-scan.json', expected: 'no ERROR-level federation lines appended to any validator log during the run', kind: logScanKind,
      note: `ERROR lines (all kinds): ${scan.map((row) => `${row.cluster}${row.index}=${row.errorLines ?? '?'}`).join(' ')}`,
      observed: scan.map((row) => `${row.cluster}${row.index}=${row.federationErrors ?? '?'}`).join(' '),
      scenarioId: s.phase, status: !scanned ? STATUS.UNKNOWN : scan.every((row) => row.federationErrors === 0) ? STATUS.PASS : STATUS.FAIL,
    });

    const result = summarize(assertions);
    const summary = {
      aborted, abortedInPhase: aborted ? endPhase : null, endedAt: now().toISOString(), evidenceDir: dir,
      requests: stats.requests, startedAt: startedAt.toISOString(), writeRequests: stats.writes, ...extraSummary, ...result,
    };
    const header = 'phase\tassertionId\tkind\texpected\tobserved\tstatus\tevidence\tnote';
    const rows = assertions.map((row) => [row.scenarioId, row.assertionId, row.kind, row.expected, row.observed, row.status, row.evidence, row.note].map(cell).join('\t'));
    s.write('assertions.tsv', `${[header, ...rows].join('\n')}\n`);
    s.write('summary.json', summary);
    s.write('report.md', [
      `# ${title} — ${summary.status}`,
      '',
      `- Evidence: \`${dir}\``,
      `- Jar: \`${manifest.jar.path ?? 'unknown'}\` (sha256 ${manifest.jar.sha256 ?? 'unknown'})`,
      `- Required: ${result.required.pass} pass, ${result.required.fail} fail, ${result.required.unknown} unknown (of ${result.required.total})`,
      `- Requests: ${stats.requests} (writes/deletes: ${stats.writes})${aborted ? `\n- Aborted in ${endPhase}: ${aborted}` : ''}`,
      ...extraReport,
      '',
      '| Phase | Assertion | Kind | Status | Observed |',
      '|---|---|---|---|---|',
      ...assertions.map((row) => `| ${row.scenarioId} | ${row.assertionId} | ${row.kind} | **${row.status}** | ${cell(row.observed).replace(/\|/g, '\\|').slice(0, 160)} |`),
      '',
    ].join('\n'));
    if (seal) sealEvidence(dir);
    log(`${summary.status === STATUS.PASS ? '✅' : '❌'} ${title} ${summary.status}: ${result.required.pass}/${result.required.total} required PASS, ${result.required.fail} FAIL, ${result.required.unknown} UNKNOWN`);
    log(`   Evidence: ${dir}`);
    return summary;
  };

  return s;
}

// CLI glue shared by the scenario entry points: topology JSON from FED_SMOKE_CONFIG plus deadline overrides.
export function configFromEnv(env = process.env, { script }) {
  let config;
  try {
    config = JSON.parse(env.FED_SMOKE_CONFIG ?? '');
  } catch {
    throw new Error(`FED_SMOKE_CONFIG must hold the topology JSON (run ${script})`);
  }
  const seconds = Number(env.FED_SMOKE_DEADLINE_SECONDS || 0);
  const pollMs = Number(env.FED_SMOKE_POLL_MS || 0);
  config.options = {
    ...(seconds > 0 ? { deadlineMs: seconds * 1000 } : {}),
    ...(pollMs > 0 ? { pollMs } : {}),
  };
  return config;
}
