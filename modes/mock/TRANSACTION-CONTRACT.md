# Valid transaction contract (as implemented by oak-segment-consensus)

The runtime is the protocol authority. Every mock script, load generator and harness client in this repo must produce transactions that are valid by these rules, not just transactions that mock mode happens to accept. The SDK and docs are clients of this contract, not its source.

**Source:** `jackrabbit-oak` `feature/blockchain-aem-poc` @ `a7c3538730`. Paths below are relative to `oak-segment-consensus/src/main/java/org/apache/jackrabbit/oak/segment/`. The settlement contract is `oak-chain-smart-contracts/contracts/ValidatorPaymentV5.sol`.

## Write: `POST /v1/propose-write`

Accepted as form-urlencoded or multipart (`http/server/handlers/WriteProposalHandler.java`).

| Field | Rule | Enforced where | Mock mode |
|---|---|---|---|
| `walletAddress` | `0x` + 40 hex. Normalized to lower case; no EIP-55 checksum check. | `WalletValidator` (API, 400) | same |
| `proposalId` | **Required.** `0x` + 64 hex (32 bytes), client-chosen and never used before. In chain-backed mode it is the id passed to `payWrite(proposalId, capabilityFlags)` and must be non-zero and unused (`ValidatorPaymentV5.sol:131-141`). | `WriteProposalHandler` (API, 400) | any unique 32-byte value |
| `ethereumTxHash` | **Required.** `0x` + hex, at least 8 characters (API). In chain-backed mode it **must equal** the confirmed settlement transaction hash, and the proof kind must be WRITE (`ProposalQueueManagerOptimized.java:2302-2324`). | API 400, then verifier rejection | The verifier skips the comparison. The mock bridge synthesizes `txHash = proposalId` (`evm/impl/SimpleEvmBridge.java:269`), so a conformant mock client sends `ethereumTxHash = proposalId`. |
| `signature` | **Required.** `0x` + hex (API). In chain-backed mode it must be a **`personal_sign` by `walletAddress` over exactly `message`**, i.e. 65-byte r‖s‖v with v = 27/28 (`ProposalQueueManagerOptimized.java:2376-2410`, `consensus/security/EthereumSignatureVerifier.java`). **Runtime prefix:** `"\x19Ethereum Signed Message:\n" + message.length() + message`, where `length()` counts **UTF-16 code units** (Java), hashed as UTF-8. That equals standard EIP-191 (UTF-8 byte length) **only for ASCII messages**. | API 400 (format). Outside mock mode it is also verified at API entry (401, `WriteProposalHandler.java:~477-505`) and again in the verifier. | Both checks are skipped. A conformant client signs anyway. |
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
| `signature` | **Required.** **Target contract (decided): `personal_sign` over exactly `contentPath`**, matching the SDK's `signDeleteProposal`. **At `a7c3538730`:** the queued DELETE carries `message = ""` (`ProposalQueueManagerOptimized.java:1603`), so chain-backed verification is over the **empty string**, binding nothing. The runtime fix is on branch `fix/delete-signature-binds-content-path` (`2ae8d600e1`, unpushed). It verifies over `contentPath` at API entry (401) and in the verifier, both outside mock mode. Conformant clients sign `contentPath`, which is harmless in mock mode, where verification is skipped. |

## Known runtime gaps observed against valid transactions

These are runtime issues, not client errors. Conformant clients still hit them.

- **Truncated values.** Replicated field extraction stops at the first escaped quote (`consensus/aeron/MessageDispatcher.java:576-595`). A valid `message` containing `"` is stored truncated on every validator, and the full message was what got signed.
- **Per-node timestamps.** Apply writes local wall-clock `timestamp`, so stored properties differ per node.

## Conformant builder in this repo

`src/tx.mjs` (CLI: `oak-chain tx key|write|delete|verify`) is the single builder that every script and the harness use.
- **Proof against the runtime:** `test/tx.test.mjs` verifies its signatures with the validator jar's own `EthereumSignatureVerifier`, covering ASCII, empty, quotes, unicode, astral characters, content paths and long messages. It also covers wrong signers and wrong messages, which must be rejected.
- **Test keys:** deterministic and public by design (`--index N`, or `--prefix HH` for a shard-local wallet). They exist only for test traffic.

- **Delete replicated as a write.** A DELETE packed into a multi-proposal batch with writes from the same wallet is replicated and applied as a **write** (templateId 106 has no type). Confirmed from source, not yet reproduced live. See `cross-lane-issues/jackrabbit-oak-delete-in-multi-proposal-batch-replicated-as-write.md`.

## Open contract questions (owner: jackrabbit-oak)

1. **What a write signature binds.** It covers `message` only, not `proposalId`, path or `organization`. Is that the intended authorization scope?
2. **Non-ASCII signing prefix.** The UTF-16 length prefix diverges from EIP-191 for non-ASCII messages. Standard wallets (MetaMask, ethers, web3j `signPrefixedMessage`) sign the UTF-8 byte length, so a non-ASCII message they sign would be rejected in chain-backed mode. The test pins this current behavior.
