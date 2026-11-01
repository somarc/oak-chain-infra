// `oak-chain tx …`: conformant transactions for shell scripts (one builder for every caller).
//
//   oak-chain tx key    [--index N | --prefix HH] [--seed S] [--private]
//   oak-chain tx write  --message M [--index N | --prefix HH | --key-env VAR] [--seed S]
//                       [--organization O] [--namespace 0x…] [--content-type T] [--proposal-id P]
//                       [--tx-hash H] [--count N] [--format form|json]
//   oak-chain tx delete --content-path P [key options] [--namespace 0x…] [--proposal-id P] [--tx-hash H]
//                       [--format form|json]
//   oak-chain tx verify --message M --signature S [--address A]
//
// --count N emits N transactions, one per line. In --message, {seq} becomes 1..N, and
// {proposalId} and {wallet} become that transaction's values (so a script can pre-sign a batch).
// --namespace writes into (or deletes from) an enterprise namespace on a federated cluster; the
// signer must be that namespace's wallet or one of its enterprise's listed writers.
// --format form prints an application/x-www-form-urlencoded body for `curl --data-binary`.
// Real keys (e.g. a funded sepolia test key) must come from --key-env VAR, never --key, so the
// secret does not appear in process listings; --key is for public test keys only.

import { buildDelete, buildWrite, newProposalId, recoverSigner, testKey, testKeyForPrefix, toForm } from './tx.mjs';

function value(options, name) {
  const raw = options[name];
  return raw === undefined || raw === true ? undefined : String(raw);
}

function keySpec(options) {
  const keyEnv = value(options, 'key-env');
  let key = value(options, 'key');
  if (keyEnv) {
    key = process.env[keyEnv];
    if (!key) throw new Error(`--key-env ${keyEnv}: environment variable is not set`);
  }
  return {
    key,
    keyIndex: value(options, 'index') ?? 0,
    prefix: value(options, 'prefix'),
    seed: value(options, 'seed'),
  };
}

function emit(fields, format) {
  return format === 'json' ? JSON.stringify(fields) : toForm(fields);
}

export function runTx(verb, options, write = (line) => process.stdout.write(`${line}\n`)) {
  const format = value(options, 'format') ?? 'form';
  if (!['form', 'json'].includes(format)) throw new Error(`--format must be form or json, got ${format}`);

  switch (verb) {
    case 'key': {
      const spec = keySpec(options);
      const key = spec.prefix ? testKeyForPrefix(spec.prefix, spec.seed) : testKey(spec.keyIndex, spec.seed);
      const out = { address: key.address, index: key.index, seed: key.seed };
      if (options.private) out.privateKey = key.privateKey;
      write(JSON.stringify(out));
      return 0;
    }
    case 'write': {
      const template = value(options, 'message');
      if (template === undefined) throw new Error('tx write needs --message (it is what gets signed)');
      const count = Number(value(options, 'count') ?? 1);
      if (!Number.isInteger(count) || count < 1) throw new Error(`--count must be a positive integer, got ${options.count}`);
      if (count > 1 && (value(options, 'proposal-id') || value(options, 'tx-hash'))) {
        throw new Error('--proposal-id/--tx-hash identify one transaction; they cannot be combined with --count');
      }
      const spec = keySpec(options);
      const signer = spec.key ? null : (spec.prefix ? testKeyForPrefix(spec.prefix, spec.seed) : testKey(spec.keyIndex, spec.seed));
      for (let seq = 1; seq <= count; seq += 1) {
        const proposalId = value(options, 'proposal-id') ?? newProposalId();
        const wallet = signer?.address ?? '';
        const message = template
          .replaceAll('{seq}', String(seq))
          .replaceAll('{proposalId}', proposalId)
          .replaceAll('{wallet}', wallet);
        write(emit(buildWrite({
          contentType: value(options, 'content-type') ?? 'page',
          ethereumTxHash: value(options, 'tx-hash'),
          key: spec.key ?? signer.privateKey,
          message,
          namespace: value(options, 'namespace'),
          organization: value(options, 'organization'),
          proposalId,
        }), format));
      }
      return 0;
    }
    case 'delete': {
      const contentPath = value(options, 'content-path');
      write(emit(buildDelete({
        ...keySpec(options),
        contentPath,
        ethereumTxHash: value(options, 'tx-hash'),
        namespace: value(options, 'namespace'),
        proposalId: value(options, 'proposal-id') ?? newProposalId(),
      }), format));
      return 0;
    }
    case 'verify': {
      const signer = recoverSigner(value(options, 'message') ?? '', value(options, 'signature') ?? '');
      const expected = value(options, 'address')?.toLowerCase();
      write(JSON.stringify({ match: expected ? signer === expected : null, signer }));
      return expected && signer !== expected ? 1 : 0;
    }
    default:
      throw new Error('Usage: oak-chain tx key|write|delete|verify (see src/tx-cli.mjs)');
  }
}
