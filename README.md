<div align="center">

# stealthpad-foundry

**Launch a coin. Holders get paid in Zcash. Nobody holds the keys.**

The Solidity contracts behind Stealthpad: a factory that launches coins on Pons V2 with a keyless
vault as their creator fee recipient, and the vault that turns creator tax into USDG, splits it by a
rule written in bytecode, and pays holders against a signed, delayed, vetoable Merkle root.

[![Solidity](https://img.shields.io/badge/Solidity-0.8.28-363636?logo=solidity&logoColor=white)](https://docs.soliditylang.org/en/v0.8.28/)
[![Foundry](https://img.shields.io/badge/built%20with-Foundry-34B27B)](https://book.getfoundry.sh/)
[![Chain](https://img.shields.io/badge/Robinhood%20Chain-4663-05110F)](https://stealthpad.online/docs#architecture)
[![Tests](https://img.shields.io/badge/tests-23%20unit%20%2B%204%20fork-77D6A8)](#testing)
[![License](https://img.shields.io/badge/license-MIT-299867)](#license)
[![Status](https://img.shields.io/badge/status-pre--mainnet-176945)](#status)

[Website](https://stealthpad.online) · [Docs](https://stealthpad.online/docs) · [App](https://app.stealthpad.online) · [Protocol spec](./PROTOCOL_SPEC.md)

</div>

---

## Status

| Item | State |
|---|---|
| Contracts (`StealthFactory`, `StealthVault`, `VaultDeployer`) | Built, 23 unit tests and 4 fork tests against live Pons V2 |
| End-to-end rehearsal on a fork of Robinhood Chain | Done: launch, buy, sell, round with tip, root, USDG claim |
| External audit | **Not yet.** Scheduled before mainnet |
| Mainnet deployment | **Not yet.** No factory address, no vault address, no $STEALTH contract address exists |

> The $STEALTH contract address will be published on launch day, from official channels only.
> Any address you see before then is not ours.

---

## What is Stealthpad

Stealthpad is a launchpad on Robinhood Chain (EVM L2, Arbitrum Orbit, chainId 4663, ETH gas).
Every coin launched through it gets its own `StealthVault`: a contract with no owner that is named, in
the launch transaction itself, as the coin's creator fee recipient on Pons V2. The creator tax of every
buy and sell, plus the creator's share of Pons V2's trading fee, lands in that vault. Rounds turn the
ETH into USDG and split it 92% to the coin's holders, 3% to whoever ran the round, 2.5% to the
$STEALTH vault and 2.5% to the treasury. Holders claim their share whenever they like, to their own
wallet in USDG or through a NEAR Intents route to Zcash or Aleo dollars.

Fee sharing, enforced by code. The vault has no keys: not ours, not the dev's.

This repository holds only the on-chain part. The off-chain worker that indexes, attests and keeps
lives in `stealthpad-warden`.

### Core mechanics

| Mechanic | Rule in code | Where |
|---|---|---|
| Creator tax | 100, 200, 300, 400 or 500 bps, chosen once, fixed forever | `StealthFactory.launch` |
| Vault as fee recipient | `creatorFeeRecipient: address(this)` filled by the vault, never by the caller | `StealthVault.launch` |
| Predictable vault address | CREATE2 from `VaultDeployer`, salt = `keccak256(launcher, salt)` | `StealthFactory.predict` |
| Round trigger | vault + escrow + curve tax >= 0.02 ETH and >= 1 hour since the last round | `roundReady`, `runRound` |
| Swap guard | min-out 150 bps below the WETH/USDG pool's 30-minute TWAP | `_ethToUsdg` |
| Per-round cap | the holders' swap takes at most 1% of the pool's USDG; the rest waits | `_roundCap` |
| Split | 92% holders · 3% caller · 2.5% $STEALTH vault · 2.5% treasury | constants |
| $STEALTH's own rounds | its 2.5% stays with its holders: 94.5 / 3 / 2.5 | `runRound` sink check |
| Roots | EIP-712 signed by the attester, relayed by anyone, one pending at a time | `postRoot` |
| Root delay | claimable 2 hours after posting; guardian may veto in that window | `ROOT_DELAY`, `veto` |
| Claims | cumulative `(holder, total to date)` leaves, nothing expires | `claim` |
| Route fee | at most 20 bps, taken only when the caller asks for it, capped by the contract | `MAX_ROUTE_FEE_BPS` |

### $STEALTH holder tiers

$STEALTH launches first on mainnet day, through this same factory, 100% on the Pons V2 bonding curve,
with a 3% creator tax to its own vault. No team allocation, no presale, fixed supply of 1,000,000,000.
Tiers use the same time-weighted snapshot as rounds.

| Tier | Share of supply | Route fee on Zcash / Aleo claims | Extra |
|---|---|---|---|
| Visitor | any | 0.20% | everything on the pad |
| Holder | >= 0.05% | 0.10% | holder badge on the claim page |
| Keeper-plus | >= 0.2% | 0% | first to use new routes |
| Core | >= 1% | 0% | a signal vote on the next route (no admin keys) |

Tier relief is applied off-chain by lowering the `feeBps` the claim page passes; the contract only
enforces the ceiling. $STEALTH never buys a larger share of any coin's rounds, a better snapshot, or
priority.

---

## How it works

```
 ┌──────────────┐  launch(input, taxBps, minOut)   ┌────────────────────┐
 │   Launcher   │ ───────────────────────────────▶ │   StealthFactory   │
 └──────────────┘        one signature             └─────────┬──────────┘
                                                             │ CREATE2 via VaultDeployer
                                                             ▼
                                                   ┌────────────────────┐   launchToken(...,
                                                   │    StealthVault    │ ── creatorFeeRecipient ──▶ Pons V2
                                                   │  (no owner, no     │     = this vault)          curve / pool
                                                   │   withdraw)        │
                                                   └─────────┬──────────┘
      every buy and sell pays creator tax (ETH)              │
      + creator share of the 1% Pons fee ──▶ Pons fee escrow ┘ claim()
                                                             │
 ┌──────────────┐        runRound()          ┌─────────────▼──────────┐
 │ Any keeper   │ ─────────────────────────▶ │ sweep, cap, TWAP-guarded│
 │ (3% tip)     │ ◀──── tip in same tx ───── │ swap ETH ─▶ USDG, split │
 └──────────────┘                            └──┬──────────┬─────────┬─┘
                                                │ 92%      │ 2.5%    │ 2.5%
                                       holders' USDG   $STEALTH vault  treasury
                                                │
 ┌──────────────┐  postRoot(round, root,        │    ┌────────────────────┐
 │  Attester    │  total, seed, sig) ──────────▶│    │ Guardian: veto()   │
 │ (signs only) │                               │◀── │ within 2 hours     │
 └──────────────┘                               ▼    └────────────────────┘
                                     root active after ROOT_DELAY
                                                │
 ┌──────────────┐ claim(cumulative, proof, to, feeBps)
 │   Holder     │ ─────────────▶ USDG to own wallet, or to the deposit address
 └──────────────┘                of the holder's own NEAR Intents quote (ZEC / Aleo)
```

1. **Launch.** The factory deploys the coin's vault at a CREATE2 address the launcher saw in advance,
   then calls `vault.launch`, which launches the coin on Pons V2 with the vault as creator fee
   recipient. Any ETH sent beyond the Pons launch fee becomes a first buy for the launcher, exempt from
   the launch-second snipe tax.
2. **Accrue.** Creator tax (ETH, both legs) and the creator share of the Pons V2 1% trading fee
   accumulate in the curve, the hook and the Pons fee escrow.
3. **Round.** Anyone calls `runRound()`. The vault sweeps and claims what the escrow holds, checks the
   cooldown and the 0.02 ETH minimum, caps the budget by pool depth, swaps the holders' share to USDG
   against a TWAP-derived min-out, pays the tip, the $STEALTH share and the treasury share, and records
   the round.
4. **Attest.** Off-chain, the attester samples 12 blocks from the window since the last round (seeded
   by this round's block hash), weights holders by average balance, applies the 100,000-token floor and
   the exclusions, builds cumulative leaves, publishes them, and signs an EIP-712 root. Anyone may
   relay the signature.
5. **Wait.** The root becomes claimable 2 hours after `postRoot`. During that window the guardian can
   `veto()` it, and the round is attested again.
6. **Claim.** A holder proves `(holder, cumulative)` against the active root and receives
   `cumulative - claimed[holder]` in USDG at `to`, minus at most 0.20% if a route fee is requested.

---

## Architecture

```
┌──────────────────────────────── Robinhood Chain (4663) ────────────────────────────────┐
│                                                                                         │
│   ┌──────────────────────┐ deploys  ┌──────────────────┐ creates  ┌──────────────────┐  │
│   │    StealthFactory    │ ───────▶ │  VaultDeployer   │ ───────▶ │  StealthVault ×N │  │
│   │ guardian · attester  │          │  (CREATE2 code   │          │  one per coin     │  │
│   │ stealthVault · list  │ ◀─────── │   holder)        │          │  immutable wiring │  │
│   └──────────┬───────────┘  reads   └──────────────────┘          └───┬─────┬─────┬───┘  │
│              │ attester(), guardian(), stealthSink()                   │     │     │      │
│              └─────────────────────────────────────────────────────────┘     │     │      │
│                                                                              │     │      │
│   ┌──────────────────────┐   launchToken / sweep / claim   ┌─────────────────▼─┐   │      │
│   │ Pons V2 LaunchFactory│ ◀────────────────────────────── │ curve · hook ·    │   │      │
│   │ curve · hook · escrow│                                 │ fee escrow        │   │      │
│   └──────────────────────┘                                 └───────────────────┘   │      │
│                                                                                    │      │
│   ┌──────────────────────┐   swap (exact in) + observe (TWAP)                      │      │
│   │ WETH/USDG Uniswap v3 │ ◀───────────────────────────────────────────────────────┘      │
│   │ pool (0.01%)         │                                                                │
│   └──────────────────────┘                                                                │
└─────────────────────────────────────────────────────────────────────────────────────────┘
            ▲ signed roots (relayed)                     ▲ claims, routes quoted in the browser
   ┌────────┴─────────┐                         ┌────────┴─────────┐
   │ stealthpad-warden│                         │ stealthpad-console│ ──▶ NEAR Intents solvers
   └──────────────────┘                         └───────────────────┘      (ZEC, Aleo dollars)
```

The container-level model, trust boundaries and message formats are in
[`PROTOCOL_SPEC.md`](./PROTOCOL_SPEC.md).

### Repository layout

```
stealthpad-foundry/
├── src/
│   ├── StealthFactory.sol        launches coins, holds the guardian and attester keys
│   ├── StealthVault.sol          one per coin: rounds, roots, claims
│   ├── VaultDeployer.sol         CREATE2 deployer, keeps the factory under the size limit
│   ├── interfaces/               IPons, IUniswapV3, IStealthFactory
│   └── lib/                      FullMath, TickMath, Twap, MerkleProof
├── test/
│   ├── StealthVault.t.sol        23 unit tests incl. a fuzz invariant
│   ├── Mocks.sol                 Pons V2, escrow, curve, WETH, USDG and v3 pool mocks
│   └── Fork.t.sol                4 tests against the real deployed contracts
├── script/Deploy.s.sol           DeployFactory · LaunchCoin · Inspect
└── foundry.toml
```

---

## Contract surface

### StealthFactory

| Function | Access | Effect |
|---|---|---|
| `launch(LaunchInput input, uint16 taxBps, uint256 minTokensOut) payable → (vault, token)` | anyone, while launches are open | deploys the vault, launches on Pons V2, optional first buy |
| `predict(address launcher, bytes32 salt, uint16 taxBps) view → address` | view | the vault address before anything is sent |
| `setStealthVault(address vault)` | guardian, once | points the 2.5% $STEALTH share at the $STEALTH coin's own vault |
| `stealthSink() view → address` | view | the $STEALTH vault once set, the treasury before |
| `proposeAttester(address next)` | guardian | queues a new attester, effective after `ATTESTER_DELAY` |
| `acceptAttester()` | anyone, after the delay | completes the attester change |
| `cancelAttester()` | guardian | drops a queued attester |
| `proposeGuardian(address next)` / `acceptGuardian()` | guardian / pending guardian | two-step guardian handover |
| `setLaunchesOpen(bool open)` | guardian | closes or reopens NEW launches only |
| `isVault(address)`, `vaultOf(address token)`, `vaults(uint256)`, `vaultCount()` | view | registry |

### StealthVault

| Function | Access | Effect |
|---|---|---|
| `launch(LaunchInput, address buyer, uint256 minTokensOut) payable` | factory, once | launches the coin with this vault as creator fee recipient |
| `sweepAndClaim() → uint256` | anyone | best-effort sweep of accrued fees, then claims the escrow credit |
| `runRound() → uint64 roundId` | anyone | sweeps, caps, swaps, splits, pays the caller's tip |
| `postRoot(uint64 roundId, bytes32 root, uint256 total, bytes32 seed, bytes signature)` | anyone relaying the attester's signature | stores a pending root, claimable after `ROOT_DELAY` |
| `veto()` | guardian, while a root is pending | deletes the pending root |
| `promote()` | anyone | activates a matured pending root (claims and `postRoot` do this on their own) |
| `claim(uint256 cumulative, bytes32[] proof, address to, uint16 feeBps) → uint256 paid` | the holder | pays the difference since the last claim |
| `claimed(address holder) view → uint256` | view | cumulative USDG already claimed |
| `roundReady()`, `pendingEth()`, `nextRoundAt()`, `roundCount()`, `rounds(id)` | view | everything a keeper needs |
| `activeRoot()`, `pendingRoot()`, `unclaimed()`, `hashPostRoot(...)`, `domainSeparator()` | view | everything a verifier or the app needs |
| `feeRouteIntact()`, `pendingOverride()` | view | whether Pons still names this vault, and any queued owner override |

`LaunchInput` is `{ string name; string symbol; string logo; string description; Socials socials; bytes32 salt; }`.
The EIP-712 domain is `("Stealthpad", "1", chainId, vault)` and the signed struct is
`PostRoot(uint64 roundId,bytes32 root,uint256 total,bytes32 seed)`.
A leaf is `keccak256(bytes.concat(keccak256(abi.encode(holder, cumulative))))`, sorted-pair hashing,
compatible with `@openzeppelin/merkle-tree`'s `StandardMerkleTree`.

### Constants

| Constant | Value | Contract |
|---|---|---|
| `HOLDERS_BPS` | 9200 (92%) | StealthVault |
| `CALLER_BPS` | 300 (3%) | StealthVault |
| `STEALTH_BPS` | 250 (2.5%) | StealthVault |
| `TREASURY_BPS` | 250 (2.5%) | StealthVault |
| `MIN_ROUND` | 0.02 ether | StealthVault |
| `COOLDOWN` | 1 hours | StealthVault |
| `ROOT_DELAY` | 2 hours | StealthVault |
| `MAX_ROUTE_FEE_BPS` | 20 (0.20%) | StealthVault |
| `IMPACT_CAP_BPS` | 100 (1% of the pool's USDG) | StealthVault |
| `SLIPPAGE_BPS` | 150 (vs the 30-minute TWAP) | StealthVault |
| `ATTESTER_DELAY` | 2 days | StealthFactory |

There is no setter for any of them. They live in bytecode.

### Events

| Contract | Event |
|---|---|
| StealthFactory | `CoinLaunched(token, vault, launcher, taxBps, curve)` · `StealthVaultSet(vault)` · `AttesterProposed(attester, effectiveAt)` · `AttesterChanged(previous, attester)` · `GuardianProposed(guardian)` · `GuardianChanged(previous, guardian)` · `LaunchesOpen(open)` |
| StealthVault | `Launched(token, curve, taxBps)` · `FeesClaimed(amount)` · `RoundRun(roundId, caller, ethBudget, usdgToHolders, tip, toStealth, toTreasury)` · `RootPosted(roundId, root, total, seed, activeAt)` · `RootVetoed(roundId, root)` · `RootActivated(roundId, root, total)` · `Claimed(holder, to, amount, fee, rootRound)` |

### Errors

| Contract | Errors |
|---|---|
| StealthFactory | `OnlyGuardian` · `OnlyPendingGuardian` · `BadTax(taxBps)` · `LaunchesClosed` · `AlreadySet` · `NotOurVault` · `NoPendingAttester` · `AttesterNotReady(effectiveAt)` · `ZeroAddress` |
| StealthVault | `OnlyFactory` · `AlreadyLaunched` · `NotLaunched` · `Reentrancy` · `CoolingDown(availableAt)` · `BelowMinimum(budget)` · `SwapOutTooLow(out, minOut)` · `OnlyPool` · `TipFailed` · `PendingRoot(activeAt)` · `BadRound` · `StaleRound` · `TotalDecreased` · `TotalTooHigh(total, available)` · `BadSignature` · `OnlyGuardian` · `NothingToVeto` · `FeeTooHigh` · `BadRecipient` · `BadProof` · `NothingToClaim` · `TransferFailed` |
| VaultDeployer | `OnlyFactory` |

### What the vault can and cannot do

| Can | Cannot |
|---|---|
| Pull creator fees the Pons fee escrow credited to it | Be upgraded, paused or migrated, by anyone |
| Swap ETH to USDG with a min-out guard and a size cap | Change its split or the coin's creator tax |
| Pay the round caller and the two protocol addresses fixed at deployment | Send funds anywhere except a valid claim, the tip or those two addresses |
| Pay claims that match the active root | Pay out more than the rounds assigned to holders |

There is no owner, no `withdraw`, no rescue, no `delegatecall`, no `selfdestruct` in `StealthVault`.

---

## Quick Start

Requirements: [Foundry](https://book.getfoundry.sh/getting-started/installation) 1.x.

```bash
git clone https://github.com/stealthpadRH/stealthpad-foundry.git
cd stealthpad-foundry

# dependencies are not vendored: install forge-std into lib/
forge install foundry-rs/forge-std@v1.16.2 --no-git

forge build
forge test                                   # 23 unit tests; the 4 fork tests skip themselves
forge test --match-test testFuzz -vv         # the vault-covers-unclaimed fuzz invariant (512 runs)
```

### Testing

Fork tests run against the **real** Pons V2 launch factory, curve, fee escrow, hook, pool manager,
WETH, USDG and WETH/USDG pool. They start at the chain head, so the public RPC is enough:

```bash
forge test --match-contract Fork --fork-url robinhood -vv
# robinhood = https://rpc.mainnet.chain.robinhood.com (see foundry.toml [rpc_endpoints])
```

The public RPC keeps roughly 15 minutes of state. For a long-lived local fork, point anvil at an
archive endpoint of your choice:

```bash
export ROBINHOOD_ARCHIVE_RPC=https://your-archive-endpoint.example
anvil --fork-url "$ROBINHOOD_ARCHIVE_RPC" --chain-id 46632 --port 8547
```

Every fork test uses fresh wallets: the well-known dev accounts are EIP-7702 sweepers on this chain
and on forks of it.

### Scripts

```bash
# 1. the factory (guardian, attester and treasury must be three different addresses)
GUARDIAN=0x.. ATTESTER=0x.. TREASURY=0x.. \
forge script script/Deploy.s.sol:DeployFactory --rpc-url robinhood --broadcast --private-key $DEPLOYER_PK

# 2. one coin; prints the predicted vault first and stops if the real one differs
FACTORY=0x.. NAME="My Coin" SYMBOL=MYC TAX_BPS=300 SALT=my-coin FIRST_BUY_WEI=0 \
forge script script/Deploy.s.sol:LaunchCoin --rpc-url robinhood --broadcast --private-key $LAUNCHER_PK

# 3. read a vault back from the chain (fee route intact? pending override? unclaimed USDG?)
VAULT=0x.. forge script script/Deploy.s.sol:Inspect --rpc-url robinhood
```

Never commit a private key. `.env` is ignored by `.gitignore`.

---

## Tech Stack

| Layer | Choice | Notes |
|---|---|---|
| Language | Solidity 0.8.28 | `evm_version = "cancun"`, optimizer 400 runs, no `via_ir` |
| Toolchain | Foundry (forge, cast, anvil) | fuzz 512 runs, invariant 64 × 64 |
| Test library | forge-std v1.16.2 | installed with `forge install` |
| Chain | Robinhood Chain, chainId 4663 | Arbitrum Orbit L2, ETH gas |
| Launch venue | Pons V2 LaunchFactory `0x7eD598BcEf8bd9Edd8C97A195C6d13f40801EC7e` | bonding curve, then a Uniswap v4 pool with the Pons hook |
| Payout asset | USDG `0x5fc5360d0400a0fd4f2af552add042d716f1d168` | swapped on the WETH/USDG Uniswap v3 pool |
| Price guard | pool's own 30-minute TWAP (`observe`) | `src/lib/Twap.sol` |
| Proofs | sorted-pair Merkle, double-hashed leaves | matches `@openzeppelin/merkle-tree` |
| Signatures | EIP-712, low-s enforced | `postRoot` accepts any relayer |

---

## Phased Roadmap

| Phase | Window | Scope |
|---|---|---|
| 0 | done | Concept locked, payout routes measured, name and brand |
| 1 | weeks 1 to 4, **now** | These contracts, fork rehearsal against live Pons V2, indexer, attester and verifier, the app, LP and docs, **external audit**, mainnet day with $STEALTH first |
| 2 | months 1 to 2 | Guardian moves to a multisig, backup attester set, Adopt mode for existing Pons coins, shielded Zcash delivery when the route supports it, automated receipts, keeper leaderboard, analytics |
| 3 | months 2 to 4 | Claim relayer (no ETH needed to claim), native Uniswap launch mode if launchers ask, Monero when NEAR Intents lists it, claim widget |
| 4 | 6 to 12 months | Vaults on other EVM chains, an SDK for launchpads, partner routes |

---

## Reference Links

| Resource | Link |
|---|---|
| Website | https://stealthpad.online |
| Docs | https://stealthpad.online/docs |
| App (pre-launch mode) | https://app.stealthpad.online |
| Protocol spec (this repo) | [PROTOCOL_SPEC.md](./PROTOCOL_SPEC.md) |
| Off-chain worker | `stealthpad-warden` |
| Read API and SDK | `stealthpad-conduit` |
| Frontend | `stealthpad-console` |
| Whitepaper and threat model | `stealthpad-dossier` |
| X | [@stealthpadRH](https://x.com/stealthpadRH) (reserved, opening soon) |
| GitHub | [github.com/stealthpadRH](https://github.com/stealthpadRH) |
| Foundry | https://book.getfoundry.sh |

---

## License

MIT, as declared by the SPDX header of every source file.

---

<div align="center">
<sub>
Stealthpad is experimental software on public blockchains and has not been audited yet. $STEALTH and every
coin launched through Stealthpad are digital tokens with no promise of value, profit or return. Payouts
depend on trading volume, which can fall to zero. Smart contracts can contain bugs despite audits and
tests. Nothing here is investment, legal or tax advice. Stealthpad is independent and not affiliated with
Robinhood, Pons, NEAR, or the Zcash and Aleo foundations.
</sub>
</div>
