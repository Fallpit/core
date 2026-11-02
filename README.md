# Fallpit Core

[![CI](https://github.com/Fallpit/core/actions/workflows/ci.yml/badge.svg)](https://github.com/Fallpit/core/actions/workflows/ci.yml)
[![License: BUSL-1.1](https://img.shields.io/badge/license-BUSL--1.1-blue.svg)](LICENSE)

The smart contracts of Fallpit, a daily game on the 4 PM New York close, on Robinhood Chain. A **house** is
one asset (a stock such as NVDA, or ETH) played in one community coin, the **chip**. Each house has one
**round** a day. A round sells tickets on where the close will land; a winning ticket pays one chip. The
house's liquidity providers take the other side, and an on-chain pricing engine moves the odds with every
fill. There is no AMM pool, no order book and no stablecoin.

Website: [fallpit.xyz](https://fallpit.xyz). X: [@fallpitxyz](https://x.com/fallpitxyz). Code: [github.com/Fallpit/core](https://github.com/Fallpit/core).
Releases: [`CHANGELOG.md`](CHANGELOG.md). Mainnet addresses: [Deployed addresses](#deployed-addresses).

## How a round works

1. **Open.** After the previous close is recorded, anyone opens the next round of a house. The round
   freezes its parameters, its clock and its menu: by default eight floors (price ranges of the close)
   and the HIGHER / LOWER pair at the previous close. Each product is an ERC-6909 ticket of
   `FallpitHook`.
2. **Commit.** A trader commits a buy or a sell and escrows the chips or tickets. The commit is priced at
   a fixed instant two seconds later, so nobody picks the price.
3. **Fill.** Anyone fills the commit with the first oracle print at or after that instant (a Pyth update,
   or a keeper print signed by a quorum and bounded by Chainlink). The filler earns the commit's fill fee.
   A commit that nobody fills in time is refunded.
4. **Live strikes.** Once at most half of the round's variance is ahead, anyone can open a second
   HIGHER / LOWER pair at the edge nearest to the price, so the round still has a near-even bet when the
   pair at the previous close has pinned. A round has room for two with the default menu.
5. **Close.** At 16:00 New York the close is recorded, the round settles on the band of the close, and
   after a short challenge window it is final. Winning tickets redeem for one chip each, with no deadline.

Stock rounds trade in the after-hours of the day before, the pre-market and the regular session. ETH and
BTC rounds trade around the clock, every day. Anyone can list a community coin against the asset it
launched on (open listing).

## Contracts

| Contract | Role |
|---|---|
| `FallpitHook` | rounds, fills, live strikes, settlement, redemption; the ERC-6909 tickets; holds the chips of every round |
| `FallpitRouter` | commit (also `openAndCommit`, `commitWithEth` and signed session orders), fill, refund, redeem |
| `LadderMath` | stateless pricing engine over 40 bands of the close |
| `PitOracle` | verifies Pyth updates and keeper-signed prints bounded by Chainlink |
| `PitVault` | the houses: LP shares, endowment, deposit and withdrawal queues |
| `ChipGuard` | which coins may be a chip |
| `CommunityTreasury` | routes a coin's launchpad fees into its house |
| `hook/PitBook` | closes, variance, calendar, round clock, default parameters, roles, risk budget |
| `hook/RoundLogic` | linked library of the hook: a round's open, settle, finalize, void and live strikes |
| `hook/PitBookLogic`, `hook/PitBookRules` | linked libraries of the book: a round's terms, ticker registration, disputes and the learned sigma's step; the bounds of the owner's settings |
| `router/SessionLogic` | linked library of the router: sessions, signed orders, vault actions and listings, their digests |
| `hook/FallpitLens`, `hook/FallpitDirectory` | read-only views for apps |
| `listing/` | `PitLister`, `AnchorRegistry`, `LaunchRecordSource`, `VaultFeeForwarder`: open listing |
| `testnet/` | `MirrorFeed`, `MirrorStockToken`, `FaucetCoin`, `TestLaunchpad`: testnet stand-ins |

No contract is upgradeable, and no role can move user, LP or endowment funds. Changes by an owner that
affect pricing take effect 24 hours after they are announced on mainnet.

- [`SPEC.md`](SPEC.md): the specification.
- [`src/hook/DESIGN.md`](src/hook/DESIGN.md) and [`src/vault/DESIGN.md`](src/vault/DESIGN.md): the reasons
  behind the rules.

```
src/        the contracts (hook/, router/, vault/, listing/, lib/, interfaces/, oracle/, testnet/)
script/     FallpitDeployer.sol (the one deployment path), DeployMainnet.s.sol, DeployTestnet.s.sol,
            DeployLocal.s.sol, CheckDeployment.s.sol
test/       math/ oracle/ vault/ hook/ listing/ integration/, and vectors/ (Python reference generators
            and their JSON output)
```

## Build and test

Requirements: [Foundry](https://getfoundry.sh) (forge 1.8 or newer). Python 3.9 or newer with numpy and
mpmath only to regenerate the test vectors.

```
git clone --recursive https://github.com/Fallpit/core.git
cd core
forge build
forge build --sizes   # every contract stays under 24,576 bytes
forge fmt --check
forge test
```

The build uses the legacy pipeline (no `via_ir`) and takes about a minute. `FOUNDRY_PROFILE=ir` builds with
`via_ir` for comparison. The suite has unit, fuzz, differential and
stateful invariant tests. `test/integration` runs the whole system: full rounds on both oracle paths,
attacks, the loss limit, the fill fee, gas (`forge test --match-path test/integration/Gas.t.sol -vv`).

### Fork tests

Fork tests read Robinhood Chain and send nothing. They are skipped unless their RPC is set:

```
FORK_RPC_4663=https://rpc.mainnet.chain.robinhood.com \
FORK_RPC_46630=https://rpc.testnet.chain.robinhood.com \
forge test --match-test "fork|Fork" -vv
```

`test/integration/SystemFork.t.sol` deploys the whole system with the mainnet delays against the live
Pyth contract and plays a real TSLA day from committed Pyth update blobs (`test/oracle/fixtures/`).

### Test vectors

```
python3 test/vectors/gen_vectors.py   # LadderMath and Gaussian vectors
python3 test/vectors/gen_mills.py     # the Mills ratio fits of Gaussian.cdf
python3 test/vectors/gen_day.py       # one simulated stock round (day.json)
```

All are deterministic. `test/vectors/ladder_house_sim.py` is the float reference of the pricing engine;
`test/integration/DaySim.t.sol` replays the round of `day.json` through the real contracts and compares
every fill.

## Running a round

Every step is a permissionless call; an off-chain keeper normally makes them.

| Step | Call |
|---|---|
| Record the close of a day | `PitBook.recordClose(ticker, day, report)` |
| Settle and finalize a round | `FallpitHook.settleRound(house, day)`, `FallpitHook.finalizeRound(house, day)` |
| Open the next round | `FallpitHook.openRound(ticker, chip, day)`, or `FallpitRouter.openAndCommit` with the first trade |
| Fill a commit | `FallpitRouter.fill(commitId, report)` (earns the fill fee), or many with `FallpitRouter.fillBatch(commitIds, reports)` (no oracle fee) |
| Open a live strike | `FallpitHook.openStrike(roundId, m, t, report)`, with `m` from `FallpitLens.strikeEdgeAt(roundId, price, ts)` |
| Refund an unfilled commit | `FallpitRouter.refund(commitId)` |
| Void a round with no close | `FallpitHook.voidRound(house, day)` |

Report formats are in `SPEC.md` section 8. An app reads a round and its whole menu with
`FallpitLens.market(roundId, price, ts)`, and tickets with `hook.balanceOf(user, roundId | product)`.

## Deployment

All settings come from environment variables; their names are in `.env.example` and in the header of each
script. Pass `--slow --gas-estimate-multiplier 400` to every broadcast.

- **Mainnet (4663):** `script/DeployMainnet.s.sol` deploys and wires everything (`run()`, then
  `createHouses()` 24 hours later). When `OWNER` is the deployer (the launch setup), every contract is
  already owned by `OWNER`: check `PitBook.owner()`, no transaction. When `OWNER` is another account, the
  book is offered to it. Then check the chain with `script/CheckDeployment.s.sol` (read-only: code, wiring,
  libraries, roles, fill fee). For an `OWNER` that is not the deployer, `OWNER` calls `requestOwnershipHandover()` on
  `PitOracle`, `ChipGuard`, `CommunityTreasury`, `AnchorRegistry` and `PitLister`, the deployer runs the
  script's `handOver()`, and `OWNER` calls `PitBook.acceptOwnership()`.
- **Testnet (46630):** `script/DeployTestnet.s.sol` (`run()`, then `createHouses()` and `setUpListing()`).
- **Local:** `script/DeployLocal.s.sol` deploys its own Uniswap v4 `PoolManager` (from `lib/v4-core`, BUSL-1.1)
  for local runs and the keeper's end-to-end test only. The live chains use the deployed `PoolManager`.
- **Close source at launch.** Every mainnet ticker launches `KeeperOnly` with no Pyth feed
  (`DeployMainnet.PYTH_AT_LAUNCH`): its fills and its close are keeper prints bounded by Chainlink, one
  source. A ticker with a Pyth feed closes on Pyth only, so a feed is added only once a Hermes key is
  entitled to it. To add one later, `OWNER` calls `PitOracle.setTicker` with the ticker's config plus its
  feed id from `DeployMainnet.pythTable()`. It takes effect 24 hours later, and from then on the ticker's
  closes are Pyth closes (the keeper records them with the Hermes update for 16:00:00). Moving a ticker's
  fills to Pyth is a book change too (`TrustlessOnly`, for TSLA and QQQ in `pythTable`).

`FallpitHook` is created through the deterministic deployment proxy
`0x4e59b44847b379578588920cA78FbF26c0B4956C` with a fixed salt.

### Deployed addresses

Every chain's record is in `deployments/<chainId>.json`: addresses, deploy block, roles, tickers and the
launchpad sources.

**Robinhood Chain mainnet (4663), Fallpit Core 0.2.0**, deployed 2026-11-02 at block 104131765. The
source is verified on [robin.etherscan.io](https://robin.etherscan.io). The 35 tickers take effect 24 hours
after the deploy (`inForceAt` in the record).

| Contract | Address |
|---|---|
| LadderMath | [`0xA13a352bbD90C65a07bA1a03a28Dd3957a81dD16`](https://robin.etherscan.io/address/0xA13a352bbD90C65a07bA1a03a28Dd3957a81dD16) |
| PitOracle | [`0x77dF165Efc8115c89E851c7FBc44D50f5A878005`](https://robin.etherscan.io/address/0x77dF165Efc8115c89E851c7FBc44D50f5A878005) |
| ChipGuard | [`0x57C5Ce7a3617eae4963CBCF036322ebd656E5017`](https://robin.etherscan.io/address/0x57C5Ce7a3617eae4963CBCF036322ebd656E5017) |
| PitVault | [`0xcD6dE584aBd8dBCDc3Add1647DC9B83c823f2578`](https://robin.etherscan.io/address/0xcD6dE584aBd8dBCDc3Add1647DC9B83c823f2578) |
| PitBook | [`0x7647ed486D5CaAdb43BBd4BEc61ef4D5A54879bA`](https://robin.etherscan.io/address/0x7647ed486D5CaAdb43BBd4BEc61ef4D5A54879bA) |
| FallpitRouter | [`0xe306253438ac6f787e4924aCfDc481CC7096B8a6`](https://robin.etherscan.io/address/0xe306253438ac6f787e4924aCfDc481CC7096B8a6) |
| FallpitHook | [`0x2a70EE5fC2A3D1FAfFA629a97BDAC0B512158a5a`](https://robin.etherscan.io/address/0x2a70EE5fC2A3D1FAfFA629a97BDAC0B512158a5a) |
| FallpitLens | [`0x4AE79551a9A203288481C2ae78B3da67E4E34b3D`](https://robin.etherscan.io/address/0x4AE79551a9A203288481C2ae78B3da67E4E34b3D) |
| FallpitDirectory | [`0x0F7d39CAc4f646e9d717326737E0E32bc918F322`](https://robin.etherscan.io/address/0x0F7d39CAc4f646e9d717326737E0E32bc918F322) |
| CommunityTreasury | [`0x2eA3D2Da5eEEb5AD9caC3821C6A5C0E7d8FA7412`](https://robin.etherscan.io/address/0x2eA3D2Da5eEEb5AD9caC3821C6A5C0E7d8FA7412) |
| AnchorRegistry | [`0x881C78A52a813b9b711514E9f0518D2faCB01F84`](https://robin.etherscan.io/address/0x881C78A52a813b9b711514E9f0518D2faCB01F84) |
| PitLister | [`0x3DaD9295176650946C65e0d88e6b0185a8133995`](https://robin.etherscan.io/address/0x3DaD9295176650946C65e0d88e6b0185a8133995) |
| VaultFeeForwarderFactory | [`0xDd3D831cF1C60aE08a9EBA9F7B9EFB734A2eF226`](https://robin.etherscan.io/address/0xDd3D831cF1C60aE08a9EBA9F7B9EFB734A2eF226) |
| RoundLogic (library) | [`0x7e0CfEdFEEEB0464B35B1774aC6fd600234524b9`](https://robin.etherscan.io/address/0x7e0CfEdFEEEB0464B35B1774aC6fd600234524b9) |
| PitBookRules (library) | [`0x04DE7daCB4A4D9Aac7b92517d8Cc68D0BEa38a5c`](https://robin.etherscan.io/address/0x04DE7daCB4A4D9Aac7b92517d8Cc68D0BEa38a5c) |
| PitBookLogic (library) | [`0xF8f561Be7c36141bD5409112371cFf2904078363`](https://robin.etherscan.io/address/0xF8f561Be7c36141bD5409112371cFf2904078363) |
| SessionLogic (library) | [`0xe46a950989CdD42B816651443f6eaefab31E6a3d`](https://robin.etherscan.io/address/0xe46a950989CdD42B816651443f6eaefab31E6a3d) |

Roles: owner, guardian and fee recipient `0xE80bbcAB9E20fc193Ef768B68d69F363a7f9a2a1`. Price signers (2 of 3):
`0x15D92cf81334Be7eEB54f12e7181e58d849Cdec6`, `0x47F3aA398FAB9eb8Da31C5e376A8a55107562E23`, `0x9D37eC937AD7bFC42AC1D9680bE3C91E5197d469`. External: Uniswap v4 `PoolManager`
`0x8366a39CC670B4001A1121B8F6A443A643e40951`.

Check a deployment read-only with `forge script script/CheckDeployment.s.sol --rpc-url <RPC>`.

## Security

See [`SECURITY.md`](SECURITY.md). The contracts have not had a third-party audit. Report a vulnerability privately to hi@fallpit.xyz. Do not
open a public issue for it.

## License

The contracts are licensed under the Business Source License 1.1 ([`LICENSE`](LICENSE)), with an
additional use grant for software that calls the deployed contracts. The license changes to MIT on
2029-10-28. The interfaces (`src/interfaces/`, `src/oracle/I*.sol`, `src/hook/IPitBook.sol`) and the tests
are MIT.
