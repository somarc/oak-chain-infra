// Campaign runner: load a campaign definition, bind and authorize the target, create the
// evidence bundle before the first action, run the scenario, and report PASS/FAIL.

import { readdir, readFile } from 'node:fs/promises';
import path from 'node:path';

import { createRun, STATUS } from './evidence.mjs';
import { createHttp } from './http.mjs';
import { SCENARIOS } from './scenarios.mjs';
import { authorizeRiskClass, captureProvenance, describeTarget, processState, resolveTarget } from './target.mjs';

const CAMPAIGN_DIR = 'modes/mock/campaigns';
const PARAM_OPTIONS = {
  'concurrency': 'concurrency',
  'convergence-seconds': 'convergenceSeconds',
  'idle-seconds': 'idleSeconds',
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
