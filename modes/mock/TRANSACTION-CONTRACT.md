# Valid transaction contract (as implemented by oak-segment-consensus)

The runtime is the protocol authority. Every mock script, load generator and harness client in this repo must produce transactions that are valid by these rules, not just transactions that mock mode happens to accept. The SDK and docs are clients of this contract, not its source.

**Source:** `jackrabbit-oak` `feature/blockchain-aem-poc`; line citations are at `a7c3538730`, behaviour is current through `7ddf1535bc`. Paths below are relative to `oak-segment-consensus/src/main/java/org/apache/jackrabbit/oak/segment/`. The settlement contract is `oak-chain-smart-contracts/contracts/ValidatorPaymentV5.sol`.

## Write: `POST /v1/propose-write`

Accepted as form-urlencoded or multipart (`http/server/handlers/WriteProposalHandler.java`).

| Field | Rule | Enforced where | Mock mode |
|---|---|---|---|
| `walletAddress` | `0x` + 40 hex. Normalized to lower case; no EIP-55 checksum check. | `WalletValidator` (API, 400) | same |
| `proposalId` | **Required.** `0x` + 64 hex (32 bytes), client-chosen and never used before. In chain-backed mode it is the id passed to `payWrite(proposalId, capabilityFlags)` and must be non-zero and unused (`ValidatorPaymentV5.sol:131-141`). | `WriteProposalHandler` (API, 400) | any unique 32-byte value |
| `ethereumTxHash` | **Required.** `0x` + hex, at least 8 characters (API). In chain-backed mode it **must equal** the confirmed settlement transaction hash, and the proof kind must be WRITE (`ProposalQueueManagerOptimized.java:2302-2324`). | API 400, then verifier rejection | The verifier skips the comparison. The mock bridge synthesizes `txHash = proposalId` (`evm/impl/SimpleEvmBridge.java:269`), so a conformant mock client sends `ethereumTxHash = proposalId`. |
| `signature` | **Required.** `0x` + hex (API). In chain-backed mode it must be a **`personal_sign` by `walletAddress` over exactly `message`**, i.e. 65-byte r‖s‖v with v = 27/28 (`ProposalQueueManagerOptimized.java:2376-2410`, `consensus/security/EthereumSignatureVerifier.java`). **Runtime prefix:** standard EIP-191, `"\x19Ethereum Signed Message:\n" + utf8ByteLength(message) + message` (since `a1741502c6`; before it, Java `String.length()`, i.e. UTF-16 code units, which matched standard wallets only for ASCII). | API 400 (format). Outside mock mode it is also verified at API entry (401, `WriteProposalHandler.java:~477-505`) and again in the verifier. | Both checks are skipped. A conformant client signs anyway. |
| `message` | Any string; no length or character rules. It is **signed verbatim**. If empty, the API substitutes `"Test content at <ts>"`. | — | same |
| `contentType` | Any string; defaults to `page`. | — | same |
| `organization` | Optional; `^[a-zA-Z0-9_-]{1,64}$` (`WalletPathUtil.validateOrganization`). | API 400 | same |
| `paymentTier` | Accepted but **not read**. The tier comes from the settlement proof. | — | ignored |
| Binary | Either `ipfsCid` (enterprise clients only, and the CID must already be known to the validator, otherwise 403/422) **or** a validator-hosted upload (multipart file, `binaryData`, `intentToken`). Not both. | API 400/403/422 | same |
| Client registration | The wallet must be registered via `/v1/register-client` (otherwise 403). | API | valid addresses are auto-registered |
| Routing | Only the leader accepts writes (followers answer 307). Writes for another shard are redirected 307 by shard authority. | API 307 | same |
| Payment proof | `from` must equal `walletAddress`; `to` must be the settlement contract. | verifier | simulated with `from = walletAddress` |

**Outcome contract:**
- **Accepted:** 202 with `operationId = proposalId`.
- **Status:** `GET /v1/ops/operations/{id}`, served by the leader only (followers return 404). States: `QUEUED` → `PROCESSING` → `COMMITTED` (PROCESSED with durability ACKED), or `FAILED` (with `sourceState=REJECTED`, or durability FAILED) or `TIMED_OUT`.
- **Legacy status:** `GET /v1/proposals/{id}/status` also reports `REJECTED`.

## Delete: `POST /v1/propose-delete`

| Field | Rule |
|---|---|
| `walletAddress`, `proposalId`, `ethereumTxHash` | As for writes. The settlement call is `payDelete`, and the proof kind must be DELETE. |
| `contentPath` | **Required.** |
| `signature` | **Required.** **Target contract (decided): `personal_sign` over exactly `contentPath`**, matching the SDK's `signDeleteProposal`. **Before `2ae8d600e1`:** the queued DELETE carried `message = ""` (`ProposalQueueManagerOptimized.java:1603`), so chain-backed verification was over the **empty string**, binding nothing. Fixed in `2ae8d600e1` (on `feature/blockchain-aem-poc`). It verifies over `contentPath` at API entry (401) and in the verifier, both outside mock mode. Conformant clients sign `contentPath`, which is harmless in mock mode, where verification is skipped. |

## Runtime gaps found against valid transactions

All found by conformant clients (harness campaigns, load runs) and fixed on `feature/blockchain-aem-poc` at `7ddf1535bc`. A cluster still running an older jar shows them until it is rebuilt.

| Gap | Symptom with valid transactions | Fixed in |
|---|---|---|
| **Truncated values** | Replicated fields ended at the first escaped quote and were never unescaped; a `message` with `"` was stored truncated on every validator. Payloads over 64 KiB were cut at the wrapped 16-bit frame length. | `4cfa810b86` (JsopTokenizer decoder), `c709290164` (derived `oak:*` properties) |
| **Packed DELETE stayed in the head** | In Oak a delete is an append like any write (a revision without the node), so packing deletes with writes is legitimate, but a DELETE packed with writes from the same wallet was routed to `applyWrite`: the node stayed with `contentType=delete`, `message=""`, while the operation reported COMMITTED (6/6 in `f1-mixed-batch`). | `c3d797282e` (batch items routed by `operation`) |
| **Concurrent writes shared a path** | Node names were `<contentType>-<millis>`; concurrent writes from one wallet/org/type collided, all COMMITTED, only the last survived (3/9 in `f1-mixed-batch`). | `0c99cb44b7` (`<contentType>-<millis>-<proposalId 8 hex>`) |
| **Per-node timestamps** | Apply stamped `timestamp`, `walletCreated`, `lastWrite` from each node's clock, so committed state differed per node. | `1cbca7e717` (Aeron cluster-log timestamp) |
| **Applied write reported REJECTED** | A lost durability ACK latched the tracker; replay acks were dropped and the proposal ended REJECTED although applied everywhere (1/1,064 in a light run). | `213266ed3e` (re-emit on replayed ack), `782e74117a` + `7ddf1535bc` (PROCESSED never becomes REJECTED; durability FAILED instead) |
| **Non-ASCII signatures** | The UTF-16 length prefix rejected standard EIP-191 signatures over non-ASCII text in chain-backed mode. | `a1741502c6` |

Still open (source-confirmed, not reproduced): packing sorts a wallet's proposals by path, so a subtree delete can overtake an earlier child write (`cross-lane-issues/jackrabbit-oak-packing-sorts-by-path-reorders-subtree-delete.md`).

## Conformant builder in this repo

`src/tx.mjs` (CLI: `oak-chain tx key|write|delete|verify`) is the single builder that every script and the harness use.
- **Proof against the runtime:** `test/tx.test.mjs` verifies its signatures with the validator jar's own `EthereumSignatureVerifier`, covering ASCII, empty, quotes, unicode, astral characters, content paths and long messages, plus a standard EIP-191 signature over non-ASCII text (accepted) and an old UTF-16-length one (rejected). Wrong signers and wrong messages must be rejected. `OAK_CONSENSUS_JAR` points the test at another build of the jar.
- **Test keys:** deterministic and public by design (`--index N`, or `--prefix HH` for a shard-local wallet). They exist only for test traffic.

## Open contract questions (owner: jackrabbit-oak)

1. **What a write signature binds.** It covers `message` only, not `proposalId`, path or `organization`. Is that the intended authorization scope?
2. **Ordering of overlapping operations from one wallet.** Per-wallet FIFO, or path order with a guard so a DELETE never overtakes an earlier proposal under its subtree? (See the open gap above.)
