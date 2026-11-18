# Crumble Arena — Contracts

**Hackathon:** Binance Agent ID Hackathon (submission 18 Nov – 9 Dec 2026, 08:00 UTC).
**Game:** Crumble Arena — Pico Park-style co-op platformer on BNB Chain. Five Agent ID
holders must reach the door together. Your `.ai` name is your character.
**Economics:** gas-only. No token, no entry fees, no prize pool, no approvals, no fund
custody. Rewards are on-chain XP, levels, badges and leaderboard rank.

## Contracts

| Contract | Purpose |
| --- | --- |
| `src/CrumbleArena.sol` | The game contract. Registration (Agent ID-gated), run attestations, daily quests, views, season + pause. |

## Agent ID integration

- Agent ID contract (SPACE ID Agent ID, ERC-721, non-transferable):
  `0x60b9262456de011f7d15a54cdd8c48baaa8b022f`
- Agent ID tokenId = `uint256(keccak256(handle))` — verified on BSC mainnet 18 Nov 2026
  (`keccak256("danzz")` is owned by Danz's wallet `0x6d811a…AA95`).
- **Gate:** `registerPlayer(tokenId, classId)` verifies `agentId.ownerOf(tokenId) == msg.sender`.
  No Agent ID → no registration, no play.
- **Identity:** profiles, rooms, team rosters and the leaderboard are keyed to the Agent ID
  tokenId. The `.ai` handle is resolved on-chain via `agentId.handleOf(address)` and
  off-chain via `tokenURI(tokenId)` → `https://agentid.prd.space.id/metadata/<handle>.json`
  (name + avatar). On-chain identity is always the tokenId, never a self-asserted string.
- **Team completion:** a run only counts as a team completion on-chain when **all 5 roster
  members submit the same `runHash`** (`TeamRunComplete` at 5/5 attestations). This is the
  co-op mechanic made on-chain and multiplies interactions (5 txs per team completion).
- **Daily quests:** `submitDailyQuest(questId, proofHash)`, once per day per quest per player,
  with streak tracking. Quest semantics are defined by the game; the `proofHash` commits to
  the off-chain quest evidence (player-attested, as disclosed).

## Owner permissions (disclosed — hackathon red line 4)

The owner (deployer wallet) can ONLY:

- `pause()` / `unpause()` the contract in an emergency;
- `startSeason()` — increments the leaderboard epoch. XP history is never touched;
- `transferOwnership(newOwner)`.

The owner **cannot**: mint anything, move user funds (there are none — no fees, no pool),
change XP rules retroactively, freeze a player's profile, or upgrade the contract
(non-upgradeable, immutable logic).

## Anti-cheat limits (disclosed honestly)

Run results are player-attested with a run hash; the contract is a record/identity layer,
not a referee. Mitigations: run-hash commitments, 5/5 team attestation for team
completions, off-chain plausibility filtering on the displayed leaderboard. A full
referee/ZK design is out of scope and is not pretended otherwise.

## Red-line compliance

- No QR-code / pairing-code login anywhere (the website uses Binance Wallet injected
  provider and WalletConnect only; no server-side login sessions).
- Every transaction is initiated and confirmed by the user in their own wallet. No
  bundled extra transfers; each tx does exactly one thing.
- No token, no fees, no approvals to solicit, no returns promised ("play for fun,
  gas only").
- No "Binance"/"BNB" in the project name or domain. No wallet-lookup feature: `.ai`
  names appear only as game identities (room members, team rosters, leaderboard).
- No mass account registration, no wash volume, no fake interactions.

## Build & test

```bash
cd contracts
forge build
forge test            # 28 tests, all passing
forge test --gas-report
```

## Deploy

Testnet first (BSC testnet, chain 97). Mainnet only after testnet verification passes
and Danz confirms the one-line summary. Deployments are prepared by Muse and signed by
Danz himself in his own wallet — Muse never touches a private key.

```bash
# testnet (example; deployer signs via baw)
forge create --rpc-url <bsc-testnet-rpc> --private-key <deployer-key> \
  src/CrumbleArena.sol:CrumbleArena --constructor-args 0x60b9262456de011f7d15a54cdd8c48baaa8b022f
```

Verify source on the testnet explorer after deploy, then run the end-to-end flow:
register → play → submit run → leaderboard.
