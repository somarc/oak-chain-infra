// Strict state exporter (charter §8). Runs tools/state-exporter/StateExporter.java against
// each validator's raw segment store (read-only, over HTTP, the way federation mounts read
// it) and compares the recursive canonical typed exports across validators.
//
// A node whose export failed is UNKNOWN: compareExports never reports equality while any
// node is unknown, and the caller must map that to UNKNOWN, never PASS.

import { execFile } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export const EXPORT_FORMAT = 'oak-chain-state-export-v1';
export const EXPORTER_SOURCE = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  '../../tools/state-exporter/StateExporter.java',
);
const DEFAULT_TIMEOUT_MS = 120_000;
const MAX_BUFFER = 512 * 1024 * 1024;
const STDERR_TAIL = 2000;

function tail(text, max = STDERR_TAIL) {
  const value = String(text ?? '');
  return value.length > max ? value.slice(-max) : value;
}

function parseJson(text) {
  try {
    return JSON.parse(String(text ?? '').trim());
  } catch {
    return null;
  }
}

/**
 * Export one validator. Never throws; failures come back as { ok: false, error }.
 * `execFileImpl(file, args, options, callback)` defaults to node:child_process execFile.
 */
export function exportNode({
  jar,
  url,
  paths = ['/'],
  maxNodes,
  skipHidden = false,
  java = 'java',
  timeoutMs = DEFAULT_TIMEOUT_MS,
  source = EXPORTER_SOURCE,
  execFileImpl = execFile,
} = {}) {
  const started = Date.now();
  const done = (fields) => ({
    ok: false,
    export: null,
    error: null,
    exitCode: null,
    stderrTail: '',
    ...fields,
    elapsedMs: Date.now() - started,
  });
  if (!jar) return Promise.resolve(done({ error: 'exportNode: jar is required' }));
  if (!url) return Promise.resolve(done({ error: 'exportNode: url is required' }));

  const args = ['-cp', jar, source, '--url', url];
  for (const p of paths) args.push('--path', p);
  if (maxNodes != null) args.push('--max-nodes', String(maxNodes));
  if (skipHidden) args.push('--skip-hidden');

  return new Promise((resolve) => {
    execFileImpl(java, args, { timeout: timeoutMs, maxBuffer: MAX_BUFFER, encoding: 'utf8' }, (err, stdout, stderr) => {
      const exitCode = err ? (typeof err.code === 'number' ? err.code : null) : 0;
      const stderrTail = tail(stderr);
      const parsed = parseJson(stdout);
      if (err && err.killed) {
        resolve(done({ error: `exporter timed out after ${timeoutMs} ms`, exitCode, stderrTail }));
        return;
      }
      if (!parsed || typeof parsed !== 'object') {
        const reason = err ? err.message : 'exporter printed no JSON';
        resolve(done({ error: `unparseable exporter output: ${reason}`, exitCode, stderrTail }));
        return;
      }
      if (parsed.format !== EXPORT_FORMAT) {
        resolve(done({ error: `unexpected export format ${parsed.format}`, exitCode, stderrTail }));
        return;
      }
      if (exitCode !== 0 || parsed.error) {
        const where = parsed.path ? ` at ${parsed.path}` : '';
        resolve(done({ error: `${parsed.error ?? `exit ${exitCode}`}${where}`, exitCode, stderrTail }));
        return;
      }
      if (typeof parsed.canonicalSha256 !== 'string' || !parsed.trees || typeof parsed.trees !== 'object') {
        resolve(done({ error: 'export is missing canonicalSha256 or trees', exitCode, stderrTail }));
        return;
      }
      resolve(done({ ok: true, export: parsed, exitCode, stderrTail }));
    });
  });
}

/** Export every node of a resolved target in parallel; results keep target.nodes order. */
export function exportEverywhere(target, options = {}) {
  return Promise.all(target.nodes.map(async (node) => ({
    id: node.id,
    url: node.url,
    ...(await exportNode({ ...options, url: node.url })),
  })));
}

const childPath = (parent, name) => (parent === '/' ? `/${name}` : `${parent}/${name}`);
const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);
const byName = (items) => new Map(items.map((item) => [item.name, item]));
const sortedNames = (...lists) => [...new Set(lists.flatMap((list) => list.map((item) => item.name)))].sort();

// First difference between two exported nodes, in canonical order: properties (by name;
// presence, type, array flag, values), then children (by name; presence, then recursion).
function diffNode(a, b, nodePath) {
  const propsA = byName(a.properties ?? []);
  const propsB = byName(b.properties ?? []);
  for (const name of sortedNames(a.properties ?? [], b.properties ?? [])) {
    const pa = propsA.get(name);
    const pb = propsB.get(name);
    if (!pa || !pb) return { path: nodePath, property: name, detail: `property ${name} present on ${pa ? 'first' : 'second'} only` };
    if (pa.type !== pb.type) return { path: nodePath, property: name, detail: `type ${pa.type} != ${pb.type}` };
    if (pa.array !== pb.array) return { path: nodePath, property: name, detail: `array ${pa.array} != ${pb.array}` };
    if (pa.values.length !== pb.values.length) {
      return { path: nodePath, property: name, detail: `value count ${pa.values.length} != ${pb.values.length}` };
    }
    for (let i = 0; i < pa.values.length; i += 1) {
      if (!same(pa.values[i], pb.values[i])) {
        return {
          path: nodePath,
          property: name,
          detail: `value[${i}] ${JSON.stringify(pa.values[i])} != ${JSON.stringify(pb.values[i])}`,
        };
      }
    }
    // Same shape and values; any remaining field difference is still a difference.
    if (!same(pa, pb)) return { path: nodePath, property: name, detail: 'property records differ' };
  }
  const kidsA = byName(a.children ?? []);
  const kidsB = byName(b.children ?? []);
  for (const name of sortedNames(a.children ?? [], b.children ?? [])) {
    const ca = kidsA.get(name);
    const cb = kidsB.get(name);
    const next = childPath(nodePath, name);
    if (!ca || !cb) return { path: next, detail: `child present on ${ca ? 'first' : 'second'} only` };
    const found = diffNode(ca, cb, next);
    if (found) return found;
  }
  return null;
}

/** First difference between two exports' trees, or null when the trees are identical. */
export function firstDifference(exportA, exportB) {
  const treesA = exportA?.trees ?? {};
  const treesB = exportB?.trees ?? {};
  const roots = [...new Set([...Object.keys(treesA), ...Object.keys(treesB)])].sort();
  for (const root of roots) {
    if (!(root in treesA) || !(root in treesB)) {
      return { path: root, detail: `exported path present on ${root in treesA ? 'first' : 'second'} only` };
    }
    const found = diffNode(treesA[root], treesB[root], root);
    if (found) return found;
  }
  return null;
}

/**
 * Compare per-node results from exportEverywhere. `equal` is true only when every node
 * exported successfully and all canonical digests match. firstDifference compares each
 * differing node against the first successful node and reports which pair it came from.
 */
export function compareExports(results) {
  const digests = {};
  const unknown = [];
  const good = [];
  for (const result of results) {
    if (result.ok && result.export?.canonicalSha256) {
      digests[result.id] = result.export.canonicalSha256;
      good.push(result);
    } else {
      digests[result.id] = null;
      unknown.push(result.id);
    }
  }
  let difference = null;
  const reference = good[0];
  for (const other of good.slice(1)) {
    if (other.export.canonicalSha256 === reference.export.canonicalSha256) continue;
    const found = firstDifference(reference.export, other.export)
      ?? { path: null, detail: 'canonical digests differ but trees compare equal (export metadata mismatch)' };
    difference = { ...found, between: [reference.id, other.id] };
    break;
  }
  const allMatch = good.length > 0 && good.every((r) => r.export.canonicalSha256 === reference.export.canonicalSha256);
  return {
    equal: unknown.length === 0 && allMatch,
    digests,
    unknown,
    firstDifference: difference,
  };
}
