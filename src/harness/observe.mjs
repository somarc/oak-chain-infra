// Synchronized cluster sampling. Every node is sampled in the same round so leader,
// quorum and log-position views can be compared (charter P0-03/P0-04). Missing data is
// reported as null and judged UNKNOWN by the caller, never as healthy zeroes.

import { normalizeNodeUrl } from './http.mjs';

function parseMetric(text, name) {
  const pattern = new RegExp(`^${name}(?:\\{[^}]*\\})?\\s+([-+0-9.eE]+)\\s*$`, 'm');
  const match = pattern.exec(String(text ?? ''));
  return match ? Number(match[1]) : null;
}

async function sampleNode(http, node) {
  const [health, consensus, clusterState, metrics] = await Promise.all([
    http.request(`${node.url}/health`),
    http.request(`${node.url}/v1/consensus/status`),
    http.request(`${node.url}/v1/aeron/cluster-state`),
    http.request(`${node.url}/metrics`, { headers: { Accept: 'text/plain' } }),
  ]);
  const h = health.json ?? {};
  const c = consensus.json ?? {};
  const a = clusterState.json ?? {};
  return {
    aeron: {
      currentLeader: normalizeNodeUrl(a.currentLeader),
      hasQuorum: a.quorum?.hasQuorum ?? null,
      logPosition: typeof a.logPosition === 'number' ? a.logPosition : null,
      memberId: a.memberId ?? null,
      quorumRequired: a.quorum?.required ?? null,
      role: a.role ?? null,
      status: clusterState.status,
      term: a.term ?? null,
    },
    consensus: {
      currentLeader: normalizeNodeUrl(c.currentLeader),
      role: c.currentRole ?? null,
      status: consensus.status,
    },
    health: {
      clusterHealthy: typeof h.clusterHealthy === 'boolean' ? h.clusterHealthy : null,
      reachableCount: h.reachableCount ?? null,
      role: h.currentRole ?? null,
      status: health.status,
      totalMembers: h.totalMembers ?? null,
    },
    id: node.id,
    metrics: {
      isLeader: parseMetric(metrics.text, 'oak_consensus_is_leader'),
      reachable: parseMetric(metrics.text, 'oak_validators_reachable'),
      status: metrics.status,
    },
    url: node.url,
  };
}

export async function sampleCluster(http, target) {
  const at = new Date().toISOString();
  const nodes = await Promise.all(target.nodes.map((node) => sampleNode(http, node)));
  return { at, nodes };
}

export function leadersIn(sample) {
  return sample.nodes.filter((node) => String(node.health.role).toUpperCase() === 'LEADER');
}

export async function findLeader(http, target) {
  const answers = await Promise.all(target.nodes.map(async (node) => {
    const response = await http.request(`${node.url}/health`, { timeout: 2_000 });
    return { node, role: String(response.json?.currentRole ?? '').toUpperCase() };
  }));
  const leaders = answers.filter((answer) => answer.role === 'LEADER');
  return leaders.length === 1 ? leaders[0].node : null;
}
