// Target binding, risk-class authorization and provenance (charter §3, §5.1).
//
// A run always names its runtime root explicitly in the manifest. Anything above read-only
// needs an explicit --allow-class, and the long-lived legacy root (~/oak-chain) additionally
// needs --allow-live-root (charter §3.2).

import { execFile } from 'node:child_process';
import { createHash } from 'node:crypto';
import { createReadStream } from 'node:fs';
import { readFile, stat } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { promisify } from 'node:util';

import { resolveConsoleConfig } from '../mock-console.mjs';

const run = promisify(execFile);
const SECRET_PATTERN = /(KEY|TOKEN|SECRET|PASSWORD|PASSPHRASE|PRIVATE|MNEMONIC|CREDENTIAL)/i;
const ENV_PATTERN = /^(OAK_|CLUSTER_|AERON_|IPFS_API|OPS_PROXY|PID_DIR$|LOG_DIR$)/;

export const RISK_CLASSES = Object.freeze({
  A: 'read-only',
  B: 'bounded mutation (disposable namespace, 1-2 clients, <=50 operations, no signals)',
  C: 'controlled fault',
  D: 'destructive',
});

function flag(options, name) {
  const value = options[name];
  if (typeof value === 'string') return value.toLowerCase() !== 'false';
  return Boolean(value);
}

export async function resolveTarget({ env = process.env, options = {}, repoRoot }) {
  const config = await resolveConsoleConfig({ env, options, repoRoot });
  const nodes = [...Array(config.size).keys()].map((id) => {
    const port = config.httpBase + id * config.step;
    return {
      id,
      pidFile: path.join(config.pidDir, `validator-${id}.pid`),
      port,
      storeDir: path.join(config.runtimeRoot, `validator-${id}`),
      url: `http://127.0.0.1:${port}`,
    };
  });
  const legacyRoot = path.join(config.home, 'oak-chain');
  return {
    ...config,
    isLegacyRoot: path.resolve(config.runtimeRoot) === path.resolve(legacyRoot),
    nodes,
    oakRoot: path.resolve(repoRoot, '..'),
    repoRoot,
  };
}

export function authorizeRiskClass(target, riskClass, options = {}) {
  if (!RISK_CLASSES[riskClass]) throw new Error(`Unknown risk class ${riskClass}`);
  if (riskClass === 'A') return [];
  if (riskClass === 'C' || riskClass === 'D') {
    throw new Error(`Risk class ${riskClass} (${RISK_CLASSES[riskClass]}) campaigns are not available in this harness yet`);
  }
  const allowed = String(options['allow-class'] ?? '').toUpperCase().split(/[,\s]+/).filter(Boolean);
  if (!allowed.includes(riskClass)) {
    throw new Error(
      `This campaign is risk class ${riskClass}: ${RISK_CLASSES[riskClass]}. `
      + `Confirm the target root ${target.runtimeRoot} and rerun with --allow-class ${riskClass}.`,
    );
  }
  const approvals = [`class ${riskClass}`];
  if (target.isLegacyRoot) {
    if (!flag(options, 'allow-live-root')) {
      throw new Error(
        `${target.runtimeRoot} is the long-lived legacy root, which the charter keeps read-only (§3.2). `
        + 'Rerun with --allow-live-root to approve mutation there, or target a disposable root with --runtime-root.',
      );
    }
    approvals.push('live legacy root');
  }
  return approvals;
}

async function quiet(command, args, options = {}) {
  try {
    const { stdout, stderr } = await run(command, args, { timeout: 10_000, ...options });
    return { ok: true, stderr: String(stderr), stdout: String(stdout) };
  } catch (error) {
    return { error: error.message, ok: false, stderr: String(error.stderr ?? ''), stdout: String(error.stdout ?? '') };
  }
}

async function gitState(dir) {
  const head = await quiet('git', ['-C', dir, 'rev-parse', 'HEAD']);
  if (!head.ok) return { error: 'not a git checkout', path: dir };
  const branch = await quiet('git', ['-C', dir, 'rev-parse', '--abbrev-ref', 'HEAD']);
  const status = await quiet('git', ['-C', dir, 'status', '--porcelain']);
  const dirty = status.stdout.split('\n').filter(Boolean);
  return { branch: branch.stdout.trim(), dirtyFiles: dirty.slice(0, 50), dirtyCount: dirty.length, head: head.stdout.trim(), path: dir };
}

function sha256File(file) {
  return new Promise((resolve, reject) => {
    const hash = createHash('sha256');
    createReadStream(file).on('error', reject).on('data', (chunk) => hash.update(chunk)).on('end', () => resolve(hash.digest('hex')));
  });
}

async function jarState(jarPath) {
  try {
    const info = await stat(jarPath);
    return { mtime: info.mtime.toISOString(), mtimeMs: info.mtimeMs, path: jarPath, sha256: await sha256File(jarPath), size: info.size };
  } catch (error) {
    return { error: error.code ?? error.message, path: jarPath };
  }
}

export async function processState(node) {
  let pid = null;
  try {
    pid = Number(String(await readFile(node.pidFile, 'utf8')).trim()) || null;
  } catch (_error) {
    pid = null;
  }
  const result = { commandNamesStore: false, listenerPids: [], pid, pidFile: node.pidFile, startedAt: null };
  if (pid) {
    const ps = await quiet('ps', ['-o', 'lstart=', '-o', 'command=', '-p', String(pid)]);
    const line = ps.stdout.trim();
    if (line) {
      // lstart is a fixed 24-character date ("Sun Oct  4 08:59:12 2026").
      const started = new Date(line.slice(0, 24));
      result.startedAt = Number.isNaN(started.getTime()) ? null : started.toISOString();
      result.command = line.slice(24).trim().slice(0, 400);
      result.commandNamesStore = line.includes(node.storeDir);
    }
  }
  const lsof = await quiet('lsof', ['-nP', `-iTCP:${node.port}`, '-sTCP:LISTEN', '-t']);
  result.listenerPids = lsof.stdout.split('\n').map((value) => Number(value.trim())).filter(Boolean);
  return result;
}

export async function captureProvenance(target, { env = process.env } = {}) {
  const java = await quiet('java', ['-version']);
  const environment = Object.fromEntries(
    Object.entries(env)
      .filter(([key]) => ENV_PATTERN.test(key) && !SECRET_PATTERN.test(key))
      .sort(([a], [b]) => a.localeCompare(b)),
  );
  return {
    host: {
      arch: os.arch(),
      cpus: os.cpus().length,
      java: (java.stderr || java.stdout).split('\n')[0] || null,
      memoryBytes: os.totalmem(),
      node: process.version,
      os: `${os.type()} ${os.release()}`,
    },
    jar: await jarState(path.join(target.oakRoot, 'jackrabbit-oak/oak-segment-consensus/target/oak-segment-consensus.jar')),
    repos: {
      jackrabbitOak: await gitState(path.join(target.oakRoot, 'jackrabbit-oak')),
      oakChainInfra: await gitState(target.repoRoot),
    },
    environment,
  };
}

export function describeTarget(target) {
  return {
    aeronBase: target.aeronBase,
    clusterName: target.clusterName,
    httpBase: target.httpBase,
    isLegacyRoot: target.isLegacyRoot,
    launchRecord: target.launch,
    nodes: target.nodes.map(({ id, port, storeDir, url }) => ({ id, port, storeDir, url })),
    opsPort: target.opsPort,
    pidDir: target.pidDir,
    runtimeRoot: target.runtimeRoot,
    size: target.size,
    sizeSource: target.sizeSource,
    step: target.step,
  };
}
