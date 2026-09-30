# Changelog

All notable changes to `stealthpad-foundry` are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Planned
- External audit of `StealthFactory`, `StealthVault` and `VaultDeployer` before mainnet.
- Mainnet deployment of the factory, then the $STEALTH launch through it as the first coin.
- Guardian moved to a multisig (Phase 2).

## [0.1.0] - 2026-09-29

First public cut of the contracts, as rehearsed end to end on a fork of Robinhood Chain.
Pre-mainnet: nothing here is deployed, and no contract address exists yet.

### Added
- `StealthFactory`: `launch(input, taxBps, minTokensOut)` with a creator tax of 1% to 5% in whole
  percents, fixed forever; `predict()` for the CREATE2 vault address; vault registry
  (`isVault`, `vaultOf`, `vaults`); guardian powers limited to `setStealthVault` (once),
  `proposeAttester` / `cancelAttester` behind a 2-day `ATTESTER_DELAY`, `setLaunchesOpen` for new
  launches only, and a two-step guardian handover.
- `StealthVault`: one per coin, launched on Pons V2 as the coin's deployer and creator fee recipient
  in the same transaction; optional first buy exempt from the launch-second snipe tax.
- Rounds: `runRound()` open to anyone, 0.02 ETH minimum, 1 hour cooldown, per-round cap of 1% of
  the pool's USDG, min-out 150 bps below the WETH/USDG 30-minute TWAP, split 92 / 3 / 2.5 / 2.5 with
  the caller's tip paid in the same transaction. The $STEALTH vault keeps its own 2.5% share.
- Roots: `postRoot()` accepts an EIP-712 attester signature from any relayer, one pending root at a
  time, claimable after a 2-hour `ROOT_DELAY`; `veto()` for the guardian during that window.
- Claims: cumulative `claim(cumulative, proof, to, feeBps)` to the holder's wallet or a route
  deposit address, route fee capped at 20 bps.
- Views for keepers, verifiers and the app: `roundReady`, `pendingEth`, `activeRoot`, `pendingRoot`,
  `unclaimed`, `feeRouteIntact`, `pendingOverride`, lifetime totals.
- `VaultDeployer`: CREATE2 deployer that keeps the factory under the contract size limit.
- Libraries: `FullMath`, `TickMath`, `Twap` (30-minute mean tick), `MerkleProof` (sorted pairs).
- 23 unit tests against mocks of Pons V2, the fee escrow, the curve, WETH, USDG and the v3 pool,
  including a fuzz invariant that the vault's USDG always covers unclaimed holder totals.
- 4 fork tests against the real Pons V2 contracts on Robinhood Chain: launchpad records the vault,
  a full round and claims, the $STEALTH vault's share, and fee collection after graduation on the
  real v4 pool.
- `script/Deploy.s.sol`: `DeployFactory`, `LaunchCoin` (asserts the predicted vault) and `Inspect`.
- CI: build, unit tests, advisory `forge fmt --check`, and fork tests when `ROBINHOOD_RPC_URL` is set.

### Security
- No owner, withdraw, rescue, setter, upgrade path, `delegatecall` or `selfdestruct` in the vault.
- Reentrancy guard on `launch`, `runRound`, `postRoot` and `claim`; swap callback accepts only the
  pool, only mid-swap.
- Signature malleability rejected (low-s, v in {27, 28}); EIP-712 domain rebuilt on a chain id change.
- A treasury or $STEALTH sink that refuses ETH cannot block a round.

[Unreleased]: https://github.com/stealthpadRH/stealthpad-foundry/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/stealthpadRH/stealthpad-foundry/releases/tag/v0.1.0
