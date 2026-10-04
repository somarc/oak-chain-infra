// Evidence bundle (charter §5): one directory per run, created before the first action.
//
//   manifest.json     provenance, target, approvals, campaign parameters
//   timeline.ndjson   ordered events (scenario start/end, operation state transitions)
//   ledger.ndjson     one row per mutating attempt (operation history)
//   samples.ndjson    cluster observations
//   assertions.tsv    scenarioId | assertionId | kind | expected | observed | status | evidencePath | note
//   summary.json      machine-readable result
//   report.md         human-readable result
//
// A scenario passes only if every required assertion is PASS; UNKNOWN fails it (§5.3).

import { randomBytes } from 'node:crypto';
import { appendFile, mkdir, writeFile } from 'node:fs/promises';
import path from 'node:path';

export const STATUS = Object.freeze({ FAIL: 'FAIL', PASS: 'PASS', UNKNOWN: 'UNKNOWN' });

function compactStamp(date) {
  return date.toISOString().replace(/[-:]/g, '').replace(/\.\d+Z$/, 'Z');
}

function cell(value) {
  if (value === undefined || value === null) return '';
  const text = typeof value === 'string' ? value : JSON.stringify(value);
  return text.replace(/[\t\r\n]+/g, ' ');
}

export function summarize(assertions) {
  const required = assertions.filter((row) => row.kind === 'required');
  const count = (rows, status) => rows.filter((row) => row.status === status).length;
  const failed = count(required, STATUS.FAIL);
  const unknown = count(required, STATUS.UNKNOWN);
  return {
    diagnostics: {
      fail: count(assertions.filter((row) => row.kind !== 'required'), STATUS.FAIL),
      total: assertions.length - required.length,
    },
    required: { fail: failed, pass: count(required, STATUS.PASS), total: required.length, unknown },
    status: required.length > 0 && failed === 0 && unknown === 0 ? STATUS.PASS : STATUS.FAIL,
  };
}

export async function createRun({ campaign, now = new Date(), runsDir }) {
  const id = `${campaign.id}-${compactStamp(now)}-${randomBytes(2).toString('hex')}`;
  const dir = path.join(runsDir, id);
  await mkdir(dir, { recursive: true });
  const assertions = [];
  const startedAt = now.toISOString();
  let chain = Promise.resolve();

  // Appends are serialized so ledger and timeline order match invocation order.
  const append = (name, record) => {
    chain = chain.then(() => appendFile(path.join(dir, name), `${JSON.stringify(record)}\n`));
    return chain;
  };

  const run = {
    assertions,
    dir,
    id,
    startedAt,
    async appendLedger(row) {
      await append('ledger.ndjson', { at: new Date().toISOString(), ...row });
    },
    async appendSample(sample) {
      await append('samples.ndjson', sample);
    },
    assert({ evidence = '', expected, kind = 'required', note = '', observed, scenarioId, assertionId, status }) {
      const row = { assertionId, evidence, expected, kind, note, observed, scenarioId, status };
      assertions.push(row);
      return row;
    },
    async event(type, detail = {}) {
      await append('timeline.ndjson', { at: new Date().toISOString(), type, ...detail });
    },
    async writeJson(name, value) {
      await mkdir(path.dirname(path.join(dir, name)), { recursive: true });
      await writeFile(path.join(dir, name), `${JSON.stringify(value, null, 2)}\n`);
    },
    async finish(manifest) {
      await chain;
      const endedAt = new Date().toISOString();
      const result = summarize(assertions);
      const header = 'scenarioId\tassertionId\tkind\texpected\tobserved\tstatus\tevidencePath\tnote';
      const rows = assertions.map((row) => [
        row.scenarioId, row.assertionId, row.kind, row.expected, row.observed, row.status, row.evidence, row.note,
      ].map(cell).join('\t'));
      await writeFile(path.join(dir, 'assertions.tsv'), `${[header, ...rows].join('\n')}\n`);
      const summary = { campaign: campaign.id, endedAt, runId: id, startedAt, ...result };
      await run.writeJson('summary.json', summary);
      await writeFile(path.join(dir, 'report.md'), renderReport({ assertions, campaign, manifest, summary }));
      return summary;
    },
  };
  return run;
}

export function renderReport({ assertions, campaign, manifest = {}, summary }) {
  const lines = [
    `# ${campaign.title} — ${summary.status}`,
    '',
    `- Run: \`${summary.runId}\``,
    `- Campaign: \`${campaign.id}\` (risk class ${campaign.riskClass}; charter ${campaign.charter.join(', ')})`,
    `- Target: \`${manifest.target?.runtimeRoot ?? 'unknown'}\` (${manifest.target?.size ?? '?'} members)`,
    `- Window: ${summary.startedAt} → ${summary.endedAt}`,
    `- Required: ${summary.required.pass} pass, ${summary.required.fail} fail, ${summary.required.unknown} unknown (of ${summary.required.total}); diagnostics: ${summary.diagnostics.fail} failing of ${summary.diagnostics.total}`,
    '',
    '| Scenario | Assertion | Kind | Status | Expected | Observed | Note |',
    '|---|---|---|---|---|---|---|',
  ];
  for (const row of assertions) {
    const md = (value) => cell(value).replace(/\|/g, '\\|').slice(0, 160);
    lines.push(`| ${md(row.scenarioId)} | ${md(row.assertionId)} | ${row.kind} | **${row.status}** | ${md(row.expected)} | ${md(row.observed)} | ${md(row.note)} |`);
  }
  return `${lines.join('\n')}\n`;
}
