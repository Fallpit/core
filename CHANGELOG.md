# Changelog

Fallpit Core uses [semantic versions](https://semver.org). Each release is a git tag (`vX.Y.Z`). The
deployed addresses of each chain are in `deployments/<chainId>.json`.

## 0.2.0 (2026-11-02): mainnet launch on Robinhood Chain (4663)

Deployed on Robinhood Chain mainnet. Addresses: `deployments/4663.json` and the README.

### Contracts

- **Build without via-IR.** `via_ir = false` is the default. `FOUNDRY_PROFILE=ir` keeps the via-IR build for
  comparison. `LadderMath` builds with 10,000 optimizer runs, the rest with 200.
- **Linked libraries.** `RoundLogic`, `PitBookRules`, `PitBookLogic` and `SessionLogic` hold cold code,
  deployed by CREATE2 with salt 0. `script/CheckDeployment.s.sol` checks a deployment's code, links,
  wiring and roles (read-only).
- **Gas.** A later buy 4.27M to 1.18M gas, the first buy of a round 4.97M to 1.53M, a commit 284k to 231k,
  the next day's open 5.67M to 0.84M (`test/integration/Gas.t.sol`).
- **Live strikes.** `hook.openStrike` adds a second HIGHER / LOWER pair at the price during the day. A round
  holds up to 15 products.
- **Batch fill.** `router.fillBatch(uint256[], bytes[])` fills many commits in one transaction.
- **Open and commit.** `router.openAndCommit` opens a round with its first trade.
- **Fill fee 0.000025 ETH** per commit, paid to the filler.
- **One close source per ticker.** A ticker with a Pyth feed closes on Pyth only; a ticker without one closes
  on the keeper-signed print bounded by Chainlink. A round whose close and starting close have different
  stock-token multipliers voids (`CorporateAction`).
- **Open listing.** `PitLister.listCoin` lists a coin with a seed of at least $50 (owner bounds 50 to 5,000),
  locked for 7 days. The owner creates houses with `PitLister.createHouse` (no seed).
- **Mainnet configuration.** 35 tickers, each `KeeperOnly` at launch (`DeployMainnet.PYTH_AT_LAUNCH =
  false`); ETH volatility seed 275 bps a day; 2-of-3 price signers; 24-hour delay on every owner change.
- Fixes from two internal reviews and a blind review (none critical or high).

## 0.1.0 (2026-10-28)

First public release under BUSL-1.1 (MIT on 2029-10-28). Testnet 46630.
