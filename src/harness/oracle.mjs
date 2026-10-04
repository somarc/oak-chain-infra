// Content oracles: read a node back from every validator and compare it with what the
// client submitted (value fidelity) and across validators (strict equality).
//
// Interim exporter: /api/explore returns one node with string-rendered properties. That is
// enough for value checks on string properties of bounded test content, but it is lossy
// (types dropped, arrays coerced), so it is not the charter §8 strict exporter.
//
// Per-node apply-time stamps make strict equality fail today; they are reported, and a
// semantic comparison that ignores them is a diagnostic only — it never overrides strict.

export const VOLATILE_PROPERTIES = Object.freeze(['timestamp']);

export async function readEverywhere(http, target, storagePath) {
  const query = encodeURIComponent(storagePath);
  return Promise.all(target.nodes.map(async (node) => {
    const response = await http.request(`${node.url}/api/explore?path=${query}`);
    return {
      children: Array.isArray(response.json?.children) ? response.json.children : null,
      error: response.error,
      id: node.id,
      properties: response.status === 200 ? (response.json?.properties ?? {}) : null,
      status: response.status,
    };
  }));
}

export function compareAcrossNodes(reads, { ignore = [] } = {}) {
  const present = reads.filter((read) => read.status === 200 && read.properties);
  const names = new Set(present.flatMap((read) => Object.keys(read.properties)));
  const differing = [];
  for (const name of [...names].sort()) {
    if (ignore.includes(name)) continue;
    const values = Object.fromEntries(present.map((read) => [read.id, read.properties[name] ?? null]));
    const distinct = new Set(Object.values(values).map((value) => JSON.stringify(value)));
    if (distinct.size > 1) differing.push({ name, values });
  }
  return {
    allPresent: present.length === reads.length,
    differing,
    equal: present.length === reads.length && differing.length === 0,
    missing: reads.filter((read) => read.status !== 200).map((read) => ({ id: read.id, status: read.status })),
  };
}

export function compareExpected(reads, expected) {
  const mismatches = [];
  for (const read of reads) {
    if (read.status !== 200 || !read.properties) {
      mismatches.push({ id: read.id, name: '(node)', expected: 'present', observed: `http ${read.status}` });
      continue;
    }
    for (const [name, value] of Object.entries(expected)) {
      const observed = read.properties[name];
      if (observed !== value) mismatches.push({ expected: value, id: read.id, name, observed: observed ?? null });
    }
  }
  return { equal: mismatches.length === 0, mismatches };
}

export async function waitPresentEverywhere(http, target, storagePath, { deadlineMs = 60_000, intervalMs = 1_000, sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms)) } = {}) {
  const started = Date.now();
  let reads = [];
  while (Date.now() - started <= deadlineMs) {
    reads = await readEverywhere(http, target, storagePath);
    if (reads.every((read) => read.status === 200)) return { elapsedMs: Date.now() - started, present: true, reads };
    await sleep(intervalMs);
  }
  return { elapsedMs: Date.now() - started, present: false, reads };
}

// A delete appends a revision without the node, so the head read (/api/explore) answers 404 on
// every validator. Only 404 counts as absent; a transport failure (status 0) is not evidence.
export async function waitAbsentEverywhere(http, target, storagePath, { deadlineMs = 60_000, intervalMs = 1_000, sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms)) } = {}) {
  const started = Date.now();
  let reads = [];
  while (Date.now() - started <= deadlineMs) {
    reads = await readEverywhere(http, target, storagePath);
    if (reads.every((read) => read.status === 404)) return { absent: true, elapsedMs: Date.now() - started, reads };
    await sleep(intervalMs);
  }
  return { absent: false, elapsedMs: Date.now() - started, reads, unreachable: reads.some((read) => read.status === 0) };
}
