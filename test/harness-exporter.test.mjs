import test from 'node:test';
import assert from 'node:assert/strict';

import { compareExports, EXPORT_FORMAT, exportEverywhere, exportNode, firstDifference } from '../src/harness/exporter.mjs';

const prop = (name, type, values, array = false) => ({ name, type, array, values });

function tree({ title = 'hello', titleType = 'STRING', extraChild = false } = {}) {
  const children = [
    { name: ':consensus', properties: [prop('epoch', 'LONG', ['1'])], children: [] },
    {
      name: 'content',
      properties: [prop('jcr:title', titleType, [title]), prop('tags', 'STRING', ['a', 'b'], true)],
      children: extraChild ? [{ name: 'zz', properties: [], children: [] }] : [],
    },
  ];
  return { name: '', properties: [prop('jcr:primaryType', 'NAME', ['rep:root'])], children };
}

function result(id, digest, trees) {
  return { id, ok: true, export: { format: EXPORT_FORMAT, canonicalSha256: digest, trees: { '/': trees } } };
}

test('compareExports: identical digests are equal', () => {
  const cmp = compareExports([result(0, 'aa', tree()), result(1, 'aa', tree()), result(2, 'aa', tree())]);
  assert.equal(cmp.equal, true);
  assert.deepEqual(cmp.digests, { 0: 'aa', 1: 'aa', 2: 'aa' });
  assert.deepEqual(cmp.unknown, []);
  assert.equal(cmp.firstDifference, null);
});

test('compareExports: value difference names node, property and value index', () => {
  const cmp = compareExports([result(0, 'aa', tree()), result(1, 'bb', tree({ title: 'bye' }))]);
  assert.equal(cmp.equal, false);
  assert.equal(cmp.firstDifference.path, '/content');
  assert.equal(cmp.firstDifference.property, 'jcr:title');
  assert.match(cmp.firstDifference.detail, /value\[0\] "hello" != "bye"/);
  assert.deepEqual(cmp.firstDifference.between, [0, 1]);
});

test('compareExports: type difference is reported before values', () => {
  const cmp = compareExports([result(0, 'aa', tree()), result(1, 'bb', tree({ titleType: 'NAME' }))]);
  assert.equal(cmp.equal, false);
  assert.equal(cmp.firstDifference.property, 'jcr:title');
  assert.equal(cmp.firstDifference.detail, 'type STRING != NAME');
});

test('compareExports: array flag difference', () => {
  const b = tree();
  b.children[1].properties[1] = prop('tags', 'STRING', ['a', 'b'], false);
  const diff = firstDifference({ trees: { '/': tree() } }, { trees: { '/': b } });
  assert.equal(diff.property, 'tags');
  assert.equal(diff.detail, 'array true != false');
});

test('compareExports: missing child is located', () => {
  const cmp = compareExports([result(0, 'aa', tree()), result(1, 'bb', tree({ extraChild: true }))]);
  assert.equal(cmp.equal, false);
  assert.equal(cmp.firstDifference.path, '/content/zz');
  assert.equal(cmp.firstDifference.detail, 'child present on second only');
});

test('compareExports: a failed node is unknown and never equal', () => {
  const failed = { id: 2, ok: false, export: null, error: 'boom' };
  const cmp = compareExports([result(0, 'aa', tree()), result(1, 'aa', tree()), failed]);
  assert.equal(cmp.equal, false);
  assert.deepEqual(cmp.unknown, [2]);
  assert.equal(cmp.digests[2], null);
  assert.equal(cmp.firstDifference, null);
});

test('compareExports: all nodes failed is not equal', () => {
  const cmp = compareExports([{ id: 0, ok: false }, { id: 1, ok: false }]);
  assert.equal(cmp.equal, false);
  assert.deepEqual(cmp.unknown, [0, 1]);
});

function fakeExec({ stdout = '', stderr = '', code = 0, killed = false, calls = [] }) {
  return (file, args, options, callback) => {
    calls.push({ file, args, options });
    const err = code === 0 && !killed ? null : Object.assign(new Error(`exit ${code}`), { code, killed });
    setImmediate(() => callback(err, stdout, stderr));
  };
}

const goodExport = {
  format: EXPORT_FORMAT,
  url: 'http://127.0.0.1:8490',
  headRevision: 'r:1',
  paths: ['/'],
  nodeCount: 3,
  propertyCount: 4,
  canonicalSha256: 'ab'.repeat(32),
  pathSha256: { '/': 'cd'.repeat(32) },
  unreadableBinaries: [],
  trees: { '/': tree() },
};

test('exportNode: builds the command line and parses a successful export', async () => {
  const calls = [];
  const res = await exportNode({
    jar: '/j.jar',
    url: 'http://127.0.0.1:8490',
    paths: ['/', '/oak-chain'],
    maxNodes: 10,
    skipHidden: true,
    java: '/usr/bin/java',
    source: 'X.java',
    execFileImpl: fakeExec({ stdout: `${JSON.stringify(goodExport)}\n`, stderr: 'noise', calls }),
  });
  assert.equal(res.ok, true);
  assert.equal(res.exitCode, 0);
  assert.equal(res.export.canonicalSha256, goodExport.canonicalSha256);
  assert.equal(res.stderrTail, 'noise');
  assert.equal(typeof res.elapsedMs, 'number');
  assert.equal(calls[0].file, '/usr/bin/java');
  assert.deepEqual(calls[0].args, [
    '-cp', '/j.jar', 'X.java', '--url', 'http://127.0.0.1:8490',
    '--path', '/', '--path', '/oak-chain', '--max-nodes', '10', '--skip-hidden',
  ]);
});

test('exportNode: traversal failure (exit 2) is an error with path', async () => {
  const stdout = JSON.stringify({ format: EXPORT_FORMAT, url: 'u', error: 'traversal failed: SegmentNotFound', path: '/a/b' });
  const res = await exportNode({ jar: 'j', url: 'u', execFileImpl: fakeExec({ stdout, code: 2 }) });
  assert.equal(res.ok, false);
  assert.equal(res.exitCode, 2);
  assert.equal(res.export, null);
  assert.match(res.error, /traversal failed: SegmentNotFound at \/a\/b/);
});

test('exportNode: max-nodes exceeded (exit 3) is an error', async () => {
  const stdout = JSON.stringify({ format: EXPORT_FORMAT, url: 'u', error: 'max-nodes 5 exceeded', path: '/x' });
  const res = await exportNode({ jar: 'j', url: 'u', execFileImpl: fakeExec({ stdout, code: 3 }) });
  assert.equal(res.ok, false);
  assert.equal(res.exitCode, 3);
  assert.match(res.error, /max-nodes 5 exceeded/);
});

test('exportNode: unparseable output, timeout and wrong format are errors', async () => {
  const garbage = await exportNode({ jar: 'j', url: 'u', execFileImpl: fakeExec({ stdout: 'INFO not json', code: 0 }) });
  assert.equal(garbage.ok, false);
  assert.match(garbage.error, /unparseable/);

  const timeout = await exportNode({ jar: 'j', url: 'u', timeoutMs: 5, execFileImpl: fakeExec({ killed: true, code: null }) });
  assert.equal(timeout.ok, false);
  assert.match(timeout.error, /timed out/);

  const wrong = await exportNode({ jar: 'j', url: 'u', execFileImpl: fakeExec({ stdout: JSON.stringify({ format: 'other' }) }) });
  assert.equal(wrong.ok, false);
  assert.match(wrong.error, /unexpected export format/);

  const missingJar = await exportNode({ url: 'u', execFileImpl: fakeExec({}) });
  assert.equal(missingJar.ok, false);
});

test('exportEverywhere: one result per node, in order, feeding compareExports', async () => {
  const target = { nodes: [{ id: 0, url: 'http://a' }, { id: 1, url: 'http://b' }] };
  const execFileImpl = (file, args, options, callback) => {
    const url = args[args.indexOf('--url') + 1];
    if (url === 'http://b') {
      setImmediate(() => callback(Object.assign(new Error('exit 2'), { code: 2 }),
        JSON.stringify({ format: EXPORT_FORMAT, url, error: 'down', path: null }), ''));
    } else {
      setImmediate(() => callback(null, JSON.stringify({ ...goodExport, url }), ''));
    }
  };
  const results = await exportEverywhere(target, { jar: 'j', execFileImpl });
  assert.deepEqual(results.map((r) => [r.id, r.url, r.ok]), [[0, 'http://a', true], [1, 'http://b', false]]);
  const cmp = compareExports(results);
  assert.equal(cmp.equal, false);
  assert.deepEqual(cmp.unknown, [1]);
});
