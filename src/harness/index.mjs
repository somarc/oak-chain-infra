// Campaign runner: load a campaign definition, bind and authorize the target, create the
// evidence bundle before the first action, run the scenario, and report PASS/FAIL.

import { mkdir, readdir, readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';

import { compactStamp, createRun, STATUS } from './evidence.mjs';
import { FAULT_SCENARIOS } from './fault-scenarios.mjs';
import { waitSettled } from './faults.mjs';
import { createHttp } from './http.mjs';
import { SCENARIOS as BASE_SCENARIOS } from './scenarios.mjs';
import { authorizeRiskClass, captureProvenance, describeTarget, processState, resolveTarget } from './target.mjs';

const CAMPAIGN_DIR = 'modes/mock/campaigns';
const SUITE_DIR = 'modes/mock/campaigns/suites';
const SCENARIOS = Object.freeze({ ...BASE_SCENARIOS, ...FAULT_SCENARIOS });
const PARAM_OPTIONS = {
  'concurrency': 'concurrency',
  'convergence-seconds': 'convergenceSeconds',
  'idle-seconds': 'idleSeconds',
  'recovery-seconds': 'recoverySeconds',
  'rounds': 'rounds',
  'sample': 'sample',
  'terminal-seconds': 'terminalSeconds',
};

function campaignDir(repoRoot) {
  return path.join(repoRoot, CAMPAIGN_DIR);
}

export async function listCampaigns(repoRoot) {
  const names = (await readdir(campaignDir(repoRoot))).filter((name) => name.endsWith('.json')).sort();
  return Promise.all(names.map(async (name) => JSON.parse(await readFile(path.join(campaignDir(repoRoot), name), 'utf8'))));
}

export async function loadCampaign(repoRoot, name) {
  const campaigns = await listCampaigns(repoRoot);
  const campaign = campaigns.find((entry) => entry.id === name);
  if (!campaign) throw new Error(`Unknown campaign ${name}. Available: ${campaigns.map((entry) => entry.id).join(', ')}`);
  if (!SCENARIOS[campaign.scenario]) throw new Error(`Campaign ${name} names unknown scenario ${campaign.scenario}`);
  return campaign;
}

async function loadAcceptedRecords(dir) {
  if (!dir) throw new Error('This campaign needs --accepted DIR (a load run\'s *-accepted-* directory of client-N.ndjson files)');
  const files = (await readdir(dir)).filter((name) => name.endsWith('.ndjson')).sort();
  if (files.length === 0) throw new Error(`No .ndjson files in ${dir}`);
  const records = [];
  for (const file of files) {
    const text = await readFile(path.join(dir, file), 'utf8');
    for (const line of text.split('\n')) {
      if (!line.trim()) continue;
      try {
        records.push(JSON.parse(line));
      } catch (_error) {
        records.push({ invalidLine: line.slice(0, 200) });
      }
    }
  }
  return records;
}

export async function runCampaign(name, options = {}, { env = process.env, fetchImpl, log = () => {}, repoRoot }) {
  const campaign = await loadCampaign(repoRoot, name);
  const target = await resolveTarget({ env, options, repoRoot });
  const approvals = authorizeRiskClass(target, campaign.riskClass, options);
  const params = { ...(campaign.params ?? {}) };
  for (const [option, param] of Object.entries(PARAM_OPTIONS)) {
    if (options[option] !== undefined && options[option] !== true) params[param] = Number(options[option]);
  }
  const acceptedRecords = campaign.scenario === 'reconcile-accepted' ? await loadAcceptedRecords(options.accepted) : null;

  const runsDir = String(options['runs-dir'] || path.join(target.runtimeRoot, 'runs'));
  const run = await createRun({ campaign, runsDir });
  log(`run ${run.id} → ${run.dir}`);
  const http = createHttp({ fetchImpl });
  const seed = String(options.seed ?? run.id);
  const manifest = {
    acceptedSource: options.accepted ?? null,
    approvals,
    campaign,
    invokedCommand: process.argv.slice(1).join(' '),
    params,
    processes: await Promise.all(target.nodes.map(processState)),
    provenance: await captureProvenance(target, { env }),
    riskClass: campaign.riskClass,
    runId: run.id,
    seed,
    startedAt: run.startedAt,
    target: describeTarget(target),
  };
  await run.writeJson('manifest.json', manifest);
  await run.event('campaign.start', { approvals, campaign: campaign.id, riskClass: campaign.riskClass });

  try {
    await SCENARIOS[campaign.scenario]({ acceptedRecords, http, manifest, run, seed, target }, params);
  } catch (error) {
    run.assert({
      assertionId: 'harness.error', expected: 'scenario completes', observed: error instanceof Error ? error.message : String(error),
      scenarioId: campaign.charter[0] ?? campaign.id, status: STATUS.UNKNOWN,
    });
    await run.event('harness.error', { message: error instanceof Error ? error.stack : String(error) });
  }

  await run.event('campaign.end', {});
  const summary = await run.finish(manifest);
  return { dir: run.dir, summary };
}

// ---------------------------------------------------------------------------------------
// Suites: an ordered list of campaigns run against one target into one evidence directory,
// with one summary and one report. Every campaign's risk class is authorized before the first
// action. After a fault campaign (class C) the cluster must settle again; if it does not, the
// remaining campaigns are not run (charter §4.2 abort) and the suite fails.

// GC state on every member (segment and binary), so a suite report says whether a revision GC,
// a binary mark or a binary release ran inside its window. GC status is in memory: a member
// restarted during the suite reports its post-restart state, so a change can also mean a restart
// (gc.json keeps both snapshots).
export async function gcSnapshot(http, target) {
  const at = new Date().toISOString();
  const nodes = await Promise.all(target.nodes.map(async (node) => {
    const response = await http.request(`${node.url}/v1/gc/status`);
    const g = response.json ?? {};
    return {
      binary: g.binary ? { deletes: g.binary.deletes ?? null, lastMark: g.binary.lastMark ?? null, lastRelease: g.binary.lastRelease ?? null, nextMarkAt: g.binary.nextMarkAt ?? null } : null,
      id: node.id,
      segment: g.segment ? { generation: g.segment.generation ?? null, lastRun: g.segment.lastRun ?? null, nextRun: g.segment.nextRun ?? null, oakStatus: g.segment.oakStatus ?? null, running: g.segment.running ?? null } : null,
      status: response.status,
    };
  }));
  return { at, nodes };
}

export function gcActivity(before, after) {
  const changed = [];
  for (const node of after?.nodes ?? []) {
    const prior = before?.nodes?.find((entry) => entry.id === node.id);
    if (!prior || prior.status !== 200 || node.status !== 200) {
      changed.push(`member ${node.id}: GC status unavailable`);
      continue;
    }
    if (JSON.stringify(prior.segment?.lastRun) !== JSON.stringify(node.segment?.lastRun)
      || JSON.stringify(prior.segment?.generation) !== JSON.stringify(node.segment?.generation)) changed.push(`member ${node.id}: segment GC state changed`);
    if (JSON.stringify(prior.binary?.lastMark) !== JSON.stringify(node.binary?.lastMark)) changed.push(`member ${node.id}: binary mark state changed`);
    if (JSON.stringify(prior.binary?.lastRelease) !== JSON.stringify(node.binary?.lastRelease)) changed.push(`member ${node.id}: binary release state changed`);
  }
  return changed;
}

export async function listSuites(repoRoot) {
  let names = [];
  try {
    names = (await readdir(path.join(repoRoot, SUITE_DIR))).filter((name) => name.endsWith('.json')).sort();
  } catch (_error) {
    return [];
  }
  return Promise.all(names.map(async (name) => JSON.parse(await readFile(path.join(repoRoot, SUITE_DIR, name), 'utf8'))));
}

export async function loadSuite(repoRoot, name) {
  const suites = await listSuites(repoRoot);
  const suite = suites.find((entry) => entry.id === name);
  if (!suite) throw new Error(`Unknown suite ${name}. Available: ${suites.map((entry) => entry.id).join(', ') || 'none'}`);
  const campaigns = await Promise.all(suite.campaigns.map((id) => loadCampaign(repoRoot, id)));
  return { campaigns, suite };
}

export function renderSuiteReport({ manifest, results, suite, summary }) {
  const lines = [
    `# ${suite.title} — ${summary.status}`,
    '',
    `- Suite: \`${suite.id}\` (${results.length} of ${suite.campaigns.length} campaigns run)`,
    `- Target: \`${manifest.target.runtimeRoot}\` (${manifest.target.size} members)`,
    `- Jar: \`${manifest.jar?.path ?? '?'}\` sha256 \`${manifest.jar?.sha256 ?? '?'}\` (${manifest.jar?.source ?? '?'})`,
    `- Window: ${summary.startedAt} → ${summary.endedAt}`,
    `- Required assertions: ${summary.required.pass} pass, ${summary.required.fail} fail, ${summary.required.unknown} unknown (of ${summary.required.total})`,
    ...(summary.abortedAfter ? [`- **Aborted** after \`${summary.abortedAfter}\`: ${summary.abortReason}`] : []),
    `- GC during the suite: ${summary.gcDuringSuite?.length ? summary.gcDuringSuite.join('; ') : 'none observed'} (snapshots in gc.json; a restarted member resets its in-memory GC status)`,
    '',
    '| Campaign | Class | Charter | Status | Required pass/fail/unknown | Diagnostics failing | Evidence |',
    '|---|---|---|---|---|---|---|',
  ];
  for (const result of results) {
    const s = result.summary;
    lines.push(`| \`${result.campaign.id}\` | ${result.campaign.riskClass} | ${result.campaign.charter.join(', ')} | **${s.status}** | ${s.required.pass}/${s.required.fail}/${s.required.unknown} | ${s.diagnostics.fail}/${s.diagnostics.total} | [${path.basename(result.dir)}](${path.basename(result.dir)}/report.md) |`);
  }
  for (const id of suite.campaigns.slice(results.length)) lines.push(`| \`${id}\` | | | NOT RUN | | | |`);
  const failing = results.flatMap((result) => result.failing.map((row) => ({ ...row, campaign: result.campaign.id })));
  if (failing.length > 0) {
    lines.push('', '## Failing or unknown required assertions', '', '| Campaign | Scenario | Assertion | Status | Observed |', '|---|---|---|---|---|');
    const md = (value) => String(value ?? '').replace(/[\t\r\n]+/g, ' ').replace(/\|/g, '\\|').slice(0, 220);
    for (const row of failing) lines.push(`| \`${row.campaign}\` | ${md(row.scenarioId)} | ${md(row.assertionId)} | **${row.status}** | ${md(row.observed)} |`);
  }
  return `${lines.join('\n')}\n`;
}

export async function runSuite(name, options = {}, { env = process.env, fetchImpl, log = () => {}, repoRoot, settle = waitSettled }) {
  const { campaigns, suite } = await loadSuite(repoRoot, name);
  const target = await resolveTarget({ env, options, repoRoot });
  for (const campaign of campaigns) authorizeRiskClass(target, campaign.riskClass, options);

  const startedAt = new Date();
  const dir = path.join(String(options['runs-dir'] || path.join(target.runtimeRoot, 'runs')), `suite-${suite.id}-${compactStamp(startedAt)}`);
  await mkdir(dir, { recursive: true });
  const provenance = await captureProvenance(target, { env });
  const manifest = { invokedCommand: process.argv.slice(1).join(' '), jar: provenance.jar, provenance, suite, target: describeTarget(target) };
  await writeFile(path.join(dir, 'manifest.json'), `${JSON.stringify(manifest, null, 2)}\n`);
  log(`suite ${suite.id} → ${dir}`);

  const http = createHttp({ fetchImpl });
  const gcBefore = await gcSnapshot(http, target);
  const results = [];
  let abortedAfter = null;
  let abortReason = null;
  for (const campaign of campaigns) {
    log(`▶ ${campaign.id} (class ${campaign.riskClass})`);
    const result = await runCampaign(campaign.id, { ...options, 'runs-dir': dir }, { env, fetchImpl, log, repoRoot });
    const tsv = await readFile(path.join(result.dir, 'assertions.tsv'), 'utf8');
    const failing = tsv.trim().split('\n').slice(1).map((line) => line.split('\t'))
      .filter(([, , kind, , , status]) => kind === 'required' && status !== STATUS.PASS)
      .map(([scenarioId, assertionId, , , observed, status]) => ({ assertionId, observed, scenarioId, status }));
    results.push({ campaign, dir: result.dir, failing, summary: result.summary });
    log(`  ${result.summary.status} — required ${result.summary.required.pass}/${result.summary.required.total}`);
    if (campaign.riskClass === 'C') {
      const settled = await settle(http, target, { deadlineMs: Number(options['recovery-seconds'] ?? 180) * 1_000 });
      if (!settled.settled) {
        abortedAfter = campaign.id;
        abortReason = `cluster did not settle after the fault campaign (${settled.last})`;
        log(`✕ aborting: ${abortReason}`);
        break;
      }
    }
  }

  const required = results.reduce((acc, result) => ({
    fail: acc.fail + result.summary.required.fail,
    pass: acc.pass + result.summary.required.pass,
    total: acc.total + result.summary.required.total,
    unknown: acc.unknown + result.summary.required.unknown,
  }), { fail: 0, pass: 0, total: 0, unknown: 0 });
  const complete = results.length === campaigns.length;
  const gcAfter = await gcSnapshot(http, target);
  await writeFile(path.join(dir, 'gc.json'), `${JSON.stringify({ after: gcAfter, before: gcBefore }, null, 2)}\n`);
  const summary = {
    abortReason,
    abortedAfter,
    gcDuringSuite: gcActivity(gcBefore, gcAfter),
    campaigns: results.map((result) => ({ dir: path.basename(result.dir), id: result.campaign.id, status: result.summary.status })),
    endedAt: new Date().toISOString(),
    required,
    startedAt: startedAt.toISOString(),
    status: complete && results.every((result) => result.summary.status === STATUS.PASS) ? STATUS.PASS : STATUS.FAIL,
    suite: suite.id,
  };
  await writeFile(path.join(dir, 'summary.json'), `${JSON.stringify(summary, null, 2)}\n`);
  await writeFile(path.join(dir, 'report.md'), renderSuiteReport({ manifest, results, suite, summary }));
  return { dir, results, summary };
}

export function formatSummary({ dir, summary }, assertionsTsv = '') {
  const lines = [
    `${summary.status === STATUS.PASS ? '✔' : '✕'} ${summary.campaign}: ${summary.status}`,
    `  required ${summary.required.pass} pass · ${summary.required.fail} fail · ${summary.required.unknown} unknown (of ${summary.required.total}); diagnostics failing ${summary.diagnostics.fail}/${summary.diagnostics.total}`,
    `  evidence ${dir}`,
  ];
  if (assertionsTsv) {
    const rows = assertionsTsv.trim().split('\n').slice(1).map((line) => line.split('\t'));
    for (const [scenarioId, assertionId, kind, expected, observed, status, , note] of rows) {
      const mark = status === 'PASS' ? '✔' : (status === 'FAIL' ? '✕' : '?');
      const tag = kind === 'required' ? '' : ' (diagnostic)';
      lines.push(`  ${mark} ${scenarioId} ${assertionId}${tag}: ${observed}${note ? `  — ${note}` : ''}`);
      if (status !== 'PASS') lines.push(`      expected: ${expected}`);
    }
  }
  return `${lines.join('\n')}\n`;
}
