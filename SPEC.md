# Fallpit Core: specification

This document specifies the contracts as built. The reasons behind the rules are in `src/hook/DESIGN.md`
and `src/vault/DESIGN.md`. Where this document and the code disagree, one of them has a bug.

## 1. What it is

A daily close game. Each **round** is one asset's 16:00 New York close on one day, traded in and housed in
one community coin (the **chip**), for example "the NVDA close, played in AI". There is no USDG and no
stablecoin anywhere in the protocol.

A round runs from the previous close to its own close and is opened as soon as the round before it is
over. A stock round trades through the extended hours (the after-hours of the trading day before, the
pre-market, the regular session); a round of an asset that trades around the clock (ETH, BTC) trades
without a break, weekends included. Section 7.2 has the two clocks.

- A round has a **menu** of products, frozen when it opens. A product is one ERC-6909 ticket id of the
  hook (`id = roundId | product`), a claim on a contiguous run of the 40 bands of the close: a ticket
  redeems for exactly 1 chip when the close lands in its run and for nothing otherwise. The default menu has ten products: eight **floors** that
  cut the close into ranges ("pick the floor": NVDA between 180.10 and 181.25), and the beginner pair
  HIGHER / LOWER at the previous close. Section 7.2 has the menu.
- The hook prices every fill itself and holds the chips of every round. There is no AMM pool for a
  product and no Uniswap v4 hook.
- All products of a round are priced from **one joint state** over 40 bands of the close, so their prices
  can never contradict each other: the floors of a menu that partitions the ladder sum to one, and a set
  of products that covers every band once never costs less than the one chip it must pay (7.5).
- Trades are two-step: commit, then fill at the first oracle print of the round's one price source at or
  after the commit time plus the fill delay. Nobody picks the price.

Chains: Robinhood Chain mainnet 4663 and testnet 46630. The deterministic deployment proxy
`0x4e59b44847b379578588920cA78FbF26c0B4956C` exists on both; the hook is created through it with a fixed
salt. The router uses the Uniswap v4 PoolManager `0x8366a39cc670b4001a1121b8f6a443a643e40951` only to
swap ETH for chips on pools with no hooks (`commitWithEth`).

### Contracts

| Contract | File | Role | Owner |
|---|---|---|---|
| LadderMath | `src/LadderMath.sol` | stateless pricing engine | none |
| PitOracle | `src/PitOracle.sol` | verifies Pyth updates and keeper-signed prints | yes (section 4) |
| PitVault | `src/PitVault.sol` | the houses: LP shares, endowment, queues | none |
| ChipGuard | `src/ChipGuard.sol` | which coins may be a chip | yes (section 6) |
| CommunityTreasury | `src/CommunityTreasury.sol` | launchpad fees into a house | yes (section 6) |
| FallpitHook | `src/FallpitHook.sol` | rounds, fills, settlement, redemption; the ERC-6909 tickets; holds the chips | none |
| FallpitRouter | `src/FallpitRouter.sol` | commit (`openAndCommit`, `commitWithEth`, sessions), fill, refund, redeem | none (one-time `setHook` by its deployer, who then renounces) |
| PitBook | `src/hook/PitBook.sol` | closes, variance, calendar and clock, default parameters, roles | yes (section 7.8) |
| PitClock | `src/hook/PitClock.sol` | library: the clock of a round (rho and trading windows), in the book and the lens | none |
| PitMath | `src/hook/PitMath.sol` | library: the menu, the worst band, the product cap, the post-fill check, fees; in the hook, the book and the lens | none |
| FallpitLens | `src/hook/FallpitLens.sol` | quotes, a round's whole menu in one call (with the `dead` flag of a product priced under the minimum), the all-in cost of a product at three sizes, solvency and loss limit views | none |
| FallpitDirectory | `src/hook/FallpitDirectory.sol` | discovery for apps: the tickers (`PitBook.tickers()`) and houses (`PitVault.houseIds`) with their status, an LP's position, and `nextOpenableDay(ticker)` by the book's own `openTerms` | none |
| PitLister, AnchorRegistry, LaunchRecordSource, VaultFeeForwarder | `src/listing/` | open listing: anyone lists a coin against the stock it launched on | lister and registry: yes |
| MirrorFeed, MirrorStockToken, FaucetCoin, TestLaunchpad | `src/testnet/` | testnet only (section 9) | see there |

## 2. Units and conventions

- Solidity 0.8.26, `via_ir`, cancun. Dependencies: Uniswap `v4-core` (v4.0.0), `solady`, `forge-std`.
- No proxies, no upgradeability, no emergency withdrawal of user or LP funds. Custom errors, events on
  every state change, NatSpec on every external function.
- WAD = 1e18 fixed point for all math. Chips and tickets share the chip's decimals `d` (require
  `d <= 18`); convert with `10^(18 - d)`.
- **Every rounding goes against the trader**: what they pay is rounded up, what they receive is rounded
  down. The house never loses a unit to rounding.
- `ticker` is `bytes32`, left-aligned ASCII (`bytes32("NVDA")`). `day` is `uint32` days since 1970-01-01 of the
  New York date (`NYTime`). `house = keccak256(abi.encode(ticker, chip))`. `roundId = keccak256(abi.encode(house, day))` with its
  lowest byte cleared, so a ticket id is `roundId | product`.
- Never use `tx.origin`. Never trust `msg.sender` for identity except as stated.
- Comments and revert strings never use em dashes.
- Every contract stays under 24,576 bytes (`forge build --sizes`). The clock lives in the book and the
  views in the lens for that reason.

## 3. LadderMath (`src/LadderMath.sol`, implements `ILadderMath`)

A stateless contract (pure functions), called by the hook with STATICCALL.

**Bands.** `x = ln(close / S0)`. Inner edges `e_m = (m - 19) * sigma / 4`, m = 0..38. Band j = `[e_{j-1},
e_j)`, with `e_{-1} = -inf`, `e_39 = +inf`. Edge 19 is `x = 0` (the previous close). The engine prices
any contiguous set of bands `[lo, hi]`; a product of a round is one such set (7.2). HIGHER is `[20, 39]`,
LOWER is `[0, 19]`, a floor is a set in between or at an end.

**Prior (vol mix).** `cdf_m = (Phi(z_m(sd_1)) + 4 Phi(z_m(sd_2)) + Phi(z_m(sd_3))) / 6` with
`z_m(s) = (e_m - x) / s + s / 2` and `sd_i = sd * exp(0.2 x_i - 0.02)`, `x = -sqrt3, 0, sqrt3` (a 3-node
Gauss-Hermite mixture over the sd; the multipliers are WAD constants, each node's sd truncated to the wei),
`pi_j = cdf_j - cdf_{j-1}` (`cdf_{-1} = 0`, `cdf_39 = 1`), then floor each `pi_j` at `1e-4` and renormalise so
they sum to exactly 1e18. The vega below stays on the single normal.

**Prices and cost.** With depth `b_j = b0_j * g`:

```
p_j  = pi_j * exp((v_j - lambda) / b_j),   lambda such that sum_j p_j = 1
C(v) = lambda + sum_j b_j * (p_j - pi_j)
```

- Solve lambda on chain: safeguarded Newton in log space (`g(lambda) = ln sum exp(ln pi_j + (v_j - lambda)/b_j)`),
  bisection fallback, at most 64 iterations, revert if `|sum p - 1| > 1e-12`. No caller-supplied hints.
  Log-sum-exp so nothing overflows.
- Every cost evaluation carries an error bound (`slack`); a buy is charged the computed difference plus the
  slacks, a sell is paid the difference minus them. On top a buy never costs less than `delta * pBefore` and
  a sell never pays more than `delta * pBefore`.

**`fill` order of operations** (this order is what makes depth decay unexploitable):
1. `pi = prior(sigma, ctx.x, ctx.sd)`.
2. Solve `lambda1` for `(v, pi, b0 * gOld)`. Rescale: `v_j <- lambda1 + (v_j - lambda1) * gNew / gOld`. Every
   price is unchanged by this step. Require `gNew <= gOld`.
3. `b = b0 * gNew`. `pBefore = sum of p_j over the set`. Compute `C(v)`.
4. `v_j += delta` for j in the set. Compute `C(v')`, `pAfter`.
5. `amount = C(v') - C(v)` for a buy (round up), `C(v) - C(v')` for a sell (round down).
6. `vega = |Vega(lower edge) - Vega(upper edge)|`, `Vega(e) = phi(z) * (z - sd)`, `z = (e - x) / sd + sd / 2`,
   zero for an infinite edge.

**`openDepths`.** `b0_j = alpha * capital / ln(1 / pi_j)` with `pi = prior(sigma, 0, sigma)`. The hook
does not store `b0`: it stores `openLnInv(sigma)` (the part that depends on sigma alone, packed) per house
when a round opens, and each fill derives `b0` with `depths(packed, capital, alpha)`, bit for bit equal to
`openDepths`. Requires
`alpha <= 0.79e18`, `0 < capital <= 1e33` (1e15 whole chips) and every depth at least 1e14 wei, which needs
`alpha * capital` of about 9.3e32 or more. The book's parameter bounds guarantee this for any round that
passes the hook's `minCapital` check (section 7.8).

**Domain.** `sigma` in (0, 1e18], `sd` in (0, 1e36], `|x| <= 1e36`, `g` in (0, 1e18], `|v_j|` and `|delta|`
`<= 1e36`. Inputs outside it revert with a custom error. The hook passes any `x` the oracle gives it (a stock
can move 10 sigma when sigma is 0.5%); no revert was found up to 40 sigma on the real stack.

**Normal CDF** (`src/lib/Gaussian.sol`). By the Mills ratio: 18 intervals, degree-14 Chebyshev fits
(`test/vectors/gen_mills.py`), within 1 wei of 90-digit reference vectors.

**Tests.** Differential tests against the Python reference (`test/vectors/ladder_house_sim.py`) at
1e-9 relative, fuzz (prices sum to 1, path independence, no profitable round trip, rescale moves no price,
monotone cost), exact-integer margin tests, gas; the loops run unchecked or in assembly with stated
bounds, bit-identical to a reference copy (`test/math/LadderMath.equiv.t.sol`).

## 4. PitOracle (`src/PitOracle.sol`, implements `IPitOracle`)

Free sources only.

`verifyAt(ticker, t, report)` accepts exactly one print per source for instant `t`: the first print at or
after `t` (`prevTs < t <= ts <= t + maxLag`). The first byte of `report` selects the source.
`verifyCloseAt(ticker, t, report)` is the same rule with the ticker's `closeMaxLag` (default 300 s, 60 to
900) in place of `maxLag`; the book verifies closes with it: a keeper that is down for a
few seconds or minutes at 16:00:00 still produces the close, because its first print after the outage
covers 16:00:00 and is at most `closeMaxLag` late. It is still the one print that covers the instant.
Fills keep `maxLag`. Two views serve the book: `boundBps(ticker)` and `multiplier(ticker)` (the stock
token's current `uiMultiplier`, 1e18 without one).

- **`0x01` Pyth.** `report[1:]` is the Hermes update blob. The oracle calls
  `pyth.parsePriceFeedUpdatesUnique{value: fee}([blob], [feedId], t, t + maxLag)`, which enforces
  `prevPublishTime < t <= publishTime`. Requires `price > 0`, `conf / price <= maxConfBps`, exponent in
  `[-18, 0]`, and checks the returned feed id. Returns `trustless = true`. Pyth core is
  `0x8250f4aF4B972684F7b336503E2D6dFeDeB1487a` on both chains; the update fee is 0 today, the oracle pays
  `getUpdateFee` from `msg.value` and refunds the rest to its caller.
- **`0x02` Keeper-signed.** `report[1:]` is `abi.encode(Print{ticker, price, ts, prevTs}, bytes[] signatures)`.
  EIP-712 over `Print(bytes32 ticker,uint256 price,uint64 ts,uint64 prevTs)`, domain name
  `"Fallpit PitOracle"`, version `"1"`, `chainId`, this contract. Signatures are 65 bytes `r || s || v`,
  low-s only, from distinct members of the signer set in ascending signer order, at least `threshold` of
  them. Requires `prevTs < t <= ts <= t + maxLag`, `ts <= block.timestamp`, `price > 0`. Returns
  `trustless = false`.

  **A keeper print is always bounded.** The ticker must have a Chainlink-style aggregator configured;
  without one the ticker has no keeper source (`SourceNotConfigured`). The print's price must be within
  `boundBps` (default 60, at most 100) of a round that was current around the print: the round in force at
  `ts`, or one that landed within 60 s after it (the push feed reports a move some seconds late). Rounds
  are found by walking back from the latest one, at most 64 rounds, and the round in force must be at most
  `maxFeedAge` (default 5 days) old at `ts`. The reference price is `answer * 10^(18 - decimals) * 1e18 /
  uiMultiplier` when the ticker has a stock token (the push feed prices the token, which is the underlying
  times the token's `uiMultiplier()`), else the answer itself. Operational consequences: a keeper close must
  be recorded before 64 newer rounds exist, and a change of `uiMultiplier` between a round and the
  verification of a print bounded by it gives a wrong reference (a known limit).

  **Why 60 and not less.** The band is the room a colluding signer quorum has, so it should be as narrow as
  honest prints allow. The Chainlink push feed writes a new round only when the price has moved 0.5% from
  the last one (or once a day), so an honest price can sit up to about 50 bps from the round in force
  without any round to confirm it. A band under about 55 bps would refuse honest prints near the edge of
  that deviation threshold, and the commits priced by them would go unfilled and refund. 60 leaves 10 bps
  for the feed's own rounding and for the difference between the keeper's quote sources and Chainlink's.
  The owner can widen a ticker's band to 100 bps at most, and narrow it freely.

**Trust in the keeper set.** The contracts cannot tell which of two validly signed prints for one instant is
the honest one: `threshold` colluding signers can sign a second print for the same second, or withhold a
print, inside the bound. At the money, a print 60 bps off changes the price of a token by about a quarter
(measured at sigma 2%: 24%). This is the trust placed in the keeper set for `KeeperOnly` tickers.

**Per-ticker config** (owner-set): Pyth feed id, aggregator, stock token, `maxLag` (default 30 s, at most
300), `maxConfBps` (default 100, at most 500), `boundBps` (default 60, at most 100), `maxFeedAge`,
`closeMaxLag` (default 300 s, 60 to 900).
A ticker is `supported` when it has an enabled Pyth feed id, or an enabled aggregator and a signer set.

**Owner limits.**
- A ticker's Pyth feed id is set once. Its (aggregator, stock token) pair is set once. A later `setTicker`
  must repeat what is in force (or fill in a source that was never set) and can change only the numeric
  limits. `SourcePinned` otherwise. The first configuration of a ticker is in force at once; every later
  one (a fill-in of a source and every limit included) takes effect `SIGNER_DELAY` later, replaces a change
  still waiting, and can be dropped with `cancelTickerChange`; `pendingConfig` shows it.
- `setSourceDisabled(ticker, source, bool)` switches a source off and on again. Off: the source verifies no
  fill at once (an emergency brake: a stopped fill is not final, the commit refunds when its window ends),
  does not count towards `supported`, and verifies no close whose instant is `SIGNER_DELAY` or more after
  the switch (`closesOffFrom`), so the close of a round open at the switch is still verified. Back on: at
  once. Nothing is re-pointed by it. No owner change can stop or pick an open round's close (hook
  DESIGN.md section 13).
- The first signer set and threshold are constructor arguments and in force at once. `setSigners` and
  `setThreshold` only schedule a change: it takes effect `SIGNER_DELAY` later, replaces any
  change still waiting (the clock restarts), and can be dropped with `cancelSignerChange`.
  `SIGNER_DELAY` is fixed at deployment, like `PitBook.OWNER_DELAY`: 24 hours on mainnet, zero on a testnet.
  `pendingSigners()` shows what is waiting and from when.

**Tests.** Unit tests with mocks; fork tests on 4663 and 46630 that verify real TSLA Pyth updates (committed
blobs, never the key); malleability, wrong chain, wrong deployment, replay for another `t`, non-unique print,
the bound and its walk, multipliers, the owner limits.

## 5. PitVault (`src/PitVault.sol`, implements `IPitVault`)

One contract, many houses. Holds plain ERC-20 chips between rounds. No owner, no pause, no sweep.

- `createHouse(ticker, chip)` is permissionless, requires `ChipGuard.check(chip).allowed` and
  `oracle.supported(ticker)`.
- **Shares** are an internal ledger per house (ERC-6909 style, `balanceOf(owner, uint256(house))`), with
  transfers, allowances and operators. Share price is `(lpAssets + 1) / (totalShares + 1e6)` (virtual
  shares against the inflation attack): a fresh house mints 1e6 shares per chip unit.
- **Unlocked house:** `deposit` mints now; `requestWithdraw` burns and pays now.
- **Locked house** (its capital is in a round): `deposit` and `requestWithdraw` are queued. Queued shares
  keep bearing the round's result. The queue is processed at one price, the price after the round's result:
  in `pullRoundCapital`, and also on the first LP call after the round returned (`deposit`,
  `requestWithdraw`, `claim`, `settle`, `processQueues`). Processing is O(1); each LP's entry is booked
  lazily (`settle`, or the LP's next call). `positionOf` shows the settled view. `claim` pays processed
  withdrawals. `cancelDeposit` returns a still-queued deposit during the round.
- **Endowment.** `donate(house, amount)` adds capital that owns no shares and can never be withdrawn. It is
  ordinary capital in every other respect: **profits and losses are shared pro rata** between the endowment
  and the shares, by capital at lock time (the shares' part rounded down). It is not a first-loss cushion: a
  cushion can be farmed by an LP who bets against its own house. Donations made during a round
  join the endowment after the round's result.
- **Inflows and outflows.** `deposit` and `donate` measure `balance after - balance before` around their
  own `transferFrom`, credit that, and revert with `InexactTransfer` unless it equals the amount sent (no
  fee-on-transfer chips, section 6). `returnRoundCapital` credits everything the vault holds above its
  books (`balance - accounted[chip]`); the hook must transfer and call in the same transaction. Chips sent
  straight to the vault are never credited to a depositor; they become part of that chip's next round
  result. Every outflow sends the nominal amount.
- **Price 0.** If a round's capital comes back as 0, shares stay valid, transfer, and redeem for 0. When new
  capital arrives they are void: the house starts a new share generation at the opening price
  (`SharesVoided`). If a round leaves fewer than `totalShares / 1e18` chip units behind the shares (a price
  drop of 1e12), that dust joins the endowment and the shares price at 0. Never divides by zero, never
  bricks.
- Only the hook (immutable address) may call `pullRoundCapital` and `returnRoundCapital`. A hook that never
  returns leaves the house locked; there is no emergency exit by design.
- Defence in depth: should a chip start to tax its transfers after its house was funded, the books stay
  exact (inflows are refused, returns are booked by what arrives) and the house loses the tax of each
  transfer out and back, a loss like any other.

**Tests.** Queues, share price across rounds, the pro rata split, a tax chip refused at `deposit` and
`donate`, a chip that starts to tax later, inflation attack, just-in-time deposits and withdrawals,
reentrancy through a hostile chip, a stateful invariant suite with fail-on-revert (books equal balance,
nothing bricks).

## 6. ChipGuard (`src/ChipGuard.sol`) and CommunityTreasury (`src/CommunityTreasury.sol`)

**ChipGuard.** `check(chip)` returns `allowed` when the chip is not refused, is not flagged
`feeOnTransfer`, has code, reports `decimals() <= 18`, has no active Doppler balance limit
(`isBalanceLimitActive()`, applied to every chip), and is trusted by one of three routes: its `extcodehash`
is a trusted template hash (all Doppler coins share one clone hash per chain), a trusted launch registry
vouches for it (`setTrustedRegistry(target, selector, matchKind)`, for example the Pons v2 factory's
`getLaunchedToken`), or the owner approved it by address. Owner functions: `setTrustedCodeHash`,
`setTrustedRegistry`, `approve(chip, bool)`, `refuse(chip, bool)`, `setFeeOnTransfer(chip, bool)`. Reads of
chips and registries are capped static calls. The guard holds no funds; refusing or flagging a chip later
stops new houses and rounds, never withdrawals or claims. On testnet each FaucetCoin is approved by
address.

**No fee-on-transfer (tax) coins.** A coin whose transfers deliver less than the amount sent is not a
chip. Two layers enforce it:
- *The flag.* `feeOnTransfer` is an owner-set flag (nothing on chain verifies it). A flagged coin is never
  `allowed`, whatever route trusts it: no house can be created in it and no round can open in it. `check`
  still returns the flag as its second value.
- *The entry points.* A tax coin the owner has not flagged still cannot fund or trade, because every
  transfer into the protocol must deliver exactly the amount sent: `PitVault.deposit` and `donate` revert
  with `InexactTransfer(sent, received)` (so `CommunityTreasury.harvest` and `sweep` revert too), and
  `FallpitRouter.commit` reverts with `BadEscrow`. A house in such a coin stays empty and never reaches
  `minCapital`.

Balance-difference accounting is kept everywhere as defence in depth (the vault books what arrived, the
router passes what reached the hook as a buy's limit, the hook checks its chip balance before a fill), so a
coin that starts to tax after it was let in cannot make any book exceed a balance; it only costs its own
holders and its house the tax.

Known limit: a house whose capital exceeds 1e15 whole chips cannot open a round (`LadderMath`'s capital
bound). Do not approve coins whose supply makes that reachable.

**CommunityTreasury.** Lets a coin's community route its launchpad fees into its house.
- Every house has one fee inbox at a fixed CREATE2 address, `inboxOf(house)`, known before it is deployed.
  The community sets **that inbox** as its Doppler fee beneficiary; the choice of inbox is the choice of
  house. (A single shared address would let the caller of `harvest` pick the house.)
- `harvest(feesManager, poolId, house)` is permissionless: the inbox calls `collectFees(poolId)`, donates
  its whole chip balance to `PitVault.donate(house, ...)`, and keeps the other pool token. `sweep(house)`
  donates chips that reached the inbox any other way. `feesManager` is untrusted: whatever it does, the
  inbox's chips can only move into its own house.
- Owner: `releaseOtherLeg(house, token, to, amount)` moves a token that is **not** the house's chip out of
  the inbox (a decision on that leg is pending). No owner path for the chip leg.

## 7. FallpitHook, FallpitRouter, PitBook

### 7.1 Access

The hook's `router` is immutable. Only the router may call `fill` and `pull` (the escrow of a sell); it
attests the user and the fill instant from its own commit record. `openRound`, `settleRound`,
`finalizeRound`, `voidRound` and `collectProtocolFees` are open to anyone; `redeem` to the holder or the
router. The router calls the hook inside its own `execute`, which accepts only the router itself under
its lock (hook DESIGN.md sections 2 and 3).

### 7.2 State

**PitBook** (split out of the hook for code size; the hook reads it through an immutable address and copies
what a round needs when the round opens). Per ticker: `varWad` (EWMA daily variance of close-to-close log
returns, weight 0.94, clamped to `[0.005^2, 0.15^2]`), `clock`, its `weights` and its `windows`, `fillSource`,
`closePrice[day]`, `closeTrustless[day]`, `lastCloseDay`, `skip[day]` (no round that day: holidays, early
closes, earnings and corporate-action days), `skipAfterHours[day]` (the round of that day does not trade in
the after-hours before it). Global: default round parameters (the menu of products among them), owner,
guardian (and the one named next, in force 24 hours after it was named), fee recipient, pause flag, the
hook (`setHook`, once, by the deployer: `dispute` reads its rounds). Each close is kept with whether it is
trustless, the stock token's multiplier when it was recorded, the end of a dispute of it, and whether a
keeper print replaced it already (`closeInfo`). A ticker's registration, like a reseed, waits 24 hours
(`pendingReseed`).

**The round clock** (`PitClock`, `IPitBook.RoundClock`). Every ticker has one of two clocks, chosen when it
is registered and never changed. A round freezes its clock when it opens (kind, the day of the close it
starts from, its own day, the weights, the windows mask, the after-hours flag); `PitBook.clockAt(clock, ts)` is a pure
function of that frozen clock and returns, for a timestamp, `rho` and whether the round trades.

`rho` is the share of the round's variance still ahead: 1 at the previous close, 0 at the round's close,
falling along straight lines in between and never rising. The engine prices every fill with
`sd = sigmaEff * sqrt(rho)` and the depth scale `g = min(g, max(sqrt(rho), 0.3))`, where `sigmaEff` is the
round's `sigma` until the book's vol keeper sets a learned one (`setSigmaEff`, section 10). `sigma` is the square root
of the EWMA of close-to-close returns times the trading days the round spans: `sigma_round = sigma_day *
sqrt(1 + k)`, `k` the weekdays without a close of their own between the close it starts from and its day
(skipped days, holidays included, and missed closes; an `EveryDay` round counts every calendar day). A
weekend is inside the daily EWMA (it is close to close) and not counted. So `sigma` is the standard
deviation of exactly the round's horizon. For a `NYWeekdays` round with `k > 0` the
frozen weights are the ticker's divided by `1 + k` and the gap gets the rest: the after-hours, the
pre-market and the regular session keep one day's share each and the `k` extra days of variance sit in
the gap, which is where they fall in time.

- **`NYWeekdays`** (stocks). A round per weekday that is not skipped, closing at 16:00:00 New York on its
  day D. It starts from the newest recorded close, of day P (the trading day before D). Four segments, each
  with a weight (basis points summing to 10000; owner-set per ticker, defaults in brackets):

  | Segment | New York time | Weight | Trades by default | Bit of `windows` |
  |---|---|---|---|---|
  | after-hours | 16:00 to 20:00 on P | `afterHours` (6%) | yes, from the moment the round is opened; not at all when `skipAfterHours` | 1 |
  | gap | 20:00 on P to 04:00 on D | `gap` (14%) | no | 2 (overnight) |
  | pre-market | 04:00 to 09:30 on D | `preMarket` (10%) | yes | 4 |
  | regular | 09:30 to 16:00 on D | `regular` (70%) | yes, until the cutoff 15:49:30 | 8 |

  Which segments trade is the ticker's `windows` mask, frozen in the round like the weights. The default
  is 13 (after-hours, pre-market, regular): nothing trades from 20:00 to 04:00. The owner can register a
  ticker with another mask, or change it later with 24 hours' notice (a reseed); the regular session is
  in every mask. **With the overnight bit (15) the weekday nights of the gap trade:** 20:00:00 of an
  evening up to 04:00:00 of the morning after, when that morning is a weekday's (Sunday evening to Friday
  morning). Then a Tuesday round trades from Monday's close to its cutoff without a break, and rho simply
  goes on falling through the night along the gap's line. Friday 20:00 to Sunday 20:00 never trades,
  whatever the mask, and neither does the daytime of a skipped day inside the gap. The mask exists so
  that the nights can be switched on for a ticker whose price source publishes then (a `TrustlessOnly`
  stock on a Pyth feed that runs 24/5) without a new deployment. `skipAfterHours` stops the after-hours
  of its evening only: a round whose nights trade starts at 20:00 that evening.

  The gap holds the night and, when there are any, the weekend and the skipped days between P and D (for a
  Monday round: Friday's after-hours, then nothing until Monday 04:00). `rho` runs through the gap in
  wall-clock time like through any other segment; on the default mask nothing fills there, so the gap's
  weight reaches the book as a jump at the first pre-market fill. Edges, to the second: the after-hours
  are `[16:00:00, 20:00:00)` (20:00:00 does not trade unless the night does), a night
  `[20:00:00, 04:00:00)`, the pre-market and the regular session together `[04:00:00, 15:49:30]` with no
  edge at 09:30. Times are wall-clock times of each day: across a
  daylight-saving switch the gap is an hour shorter or longer and the trading segments keep their length.
- **`EveryDay`** (assets that trade around the clock). A round every calendar day, closing at 16:00:00 New
  York, starting from the close of the day before. One segment (weights `(0, 0, 0, 10000)`): `rho` is one
  straight line from close to close and the round trades from the previous close to the cutoff 15:49:30,
  on every day of the week. A round lasts 24 hours (23 or 25 on the two daylight-saving Sundays).

`skip[ticker][D]` can be set or cleared only while D's close is at least 24 hours away (`SkipTooLate`
otherwise): a skip changes the horizon of the round after it, so it comes with the same notice as
everything else that prices a round. **Early-close days (13:00) are skipped like holidays**. The
calendar is off chain: the owner marks each holiday and early close with `skip` in time.

`skipAfterHours[ticker][D]` is an owner flag (immediate, no delay: it only removes trading) and is read when the round of
D opens, like everything else a round is made of: set it before the close of the day before, for example
when earnings come out after that close. A round opened with the flag is locked into as always and trades
from 04:00. The flag does not reach a round that is already open, in either direction.

**Not validated.** The pricing engine was simulated on the regular session only.
The weights above are chosen starting values, not measured
ones, and nothing in the tests says the house is paid for the risk it takes in the extended hours: thin
quotes, news after the close, and the jump of the gap all land on a book that is open. The tests show that
the contracts compute what this section says, to the unit.

**Fill source.** Every ticker is `TrustlessOnly` (Pyth) or `KeeperOnly`, frozen per round. There is no
"either": with two sources two prints qualify for one instant and the filler could pick. A ticker
whose Pyth feed the filler can read is `TrustlessOnly`; the others are `KeeperOnly`.

**The menu.** A round has 2 to 12 **products**. Product `i` is a
contiguous run of bands `[lo, hi]` (`0 <= lo <= hi <= 39`, both ends included) and one ticket id; a ticket
pays one chip when the band of the close is inside the run. Runs may overlap, and a menu need not cover the ladder: a close in a band
no product covers pays nobody, a close in a band two products share pays both. The menu is one of the
book's default parameters (`Params.menu`, one word: the lowest byte is the number of products, product
`i` has `lo` in byte `1 + 2i` and `hi` in byte `2 + 2i`, zero above the last product;
`PitBook.packMenu` and `unpackMenu` convert). It is the same for every ticker, is set by the owner like
every other default (bounded, 24 hours ahead, 7.8) and is frozen in each round's config when the round
opens. Nothing in the hook or the lens knows a particular menu.

The default menu (`PitBook.DEFAULT_MENU`): eight floors that partition the 40 bands, then the pair.

| Index | Product | Bands | In standard deviations of the day from the previous close |
|---|---|---|---|
| 0 | floor | 0 to 11 | below -2 |
| 1 | floor | 12 to 15 | -2 to -1 |
| 2 | floor | 16 to 17 | -1 to -0.5 |
| 3 | floor | 18 to 19 | -0.5 to 0 |
| 4 | floor | 20 to 21 | 0 to +0.5 |
| 5 | floor | 22 to 23 | +0.5 to +1 |
| 6 | floor | 24 to 27 | +1 to +2 |
| 7 | floor | 28 to 39 | above +2 |
| 8 | LOWER | 0 to 19 | below the previous close |
| 9 | HIGHER | 20 to 39 | at or above the previous close |

With this menu exactly one floor and exactly one half of the pair win, whatever the close. The
contracts and the tests are written for any menu
(the tests also run six floors and the pair, a six-product threshold menu, a menu that does not
partition, the pair alone, twelve products, and menus drawn at random).

Two protections come with the menu, both default parameters frozen per round:

- **Product cap** (`floorCapBps`, default 10000: switched off). The outstanding supply of a product
  narrower than half the ladder (fewer than 20 bands: a floor) may not exceed
  `capital * floorCapBps / 10000`. A buy that would take it over is rejected with `ProductCap`, a
  refundable rejection (7.3). A product of 20 bands or more (the pair) never has a product cap: only the
  per-fill cap and the loss limit bound it. Sells are never refused for the cap. In simulation a cap of
  1000 (a tenth of the capital per floor) refused about half of the retail flow at 0.5x of capital per
  day, while the loss limit at 30% protected the tail just as well, so the default is off. An owner who
  wants a cap should not set it below 5000.
- **Minimum price** (`minPriceWad`, default 0.02e18). A buy is charged at least `shares * minPriceWad`
  before fees (7.4), so a far floor cannot be bought for dust. The difference stays in the round like
  any premium. Sells are paid the engine's price. The lens flags a product whose engine price is under
  the minimum as `dead`, so that an app greys it out instead of advertising a 50x multiple on a floor
  the model prices at a tenth of a cent.

**Hook**, per round `(house, day)`: frozen config (ticker, house, chip, day, decimals, fill source, `openTs`
(the time it opened), `closeTs`, `cutoff`, the clock, `S0`, `sigma`, capital `L`, `maxFill`, the parameter
set with the menu), pricing state `v[40]` (packed, two bands a word) and its depth scale `g`, and per
product (twelve slots, the ones above the menu stay zero) the supply and the cost basis (`premium`);
chips `held`, protocol fees, status `Open -> Settled -> Final` or `Void`. Per house: the packed
`openLnInv` of its latest round (section 3), so only the latest round of a house can trade.

The hook holds the chips of every round in its own balance. `chipOwed[chip]` is the sum of every round's
`held` plus accrued protocol fees, and the hook's balance of the chip is always at least `chipOwed`.
Rounds are isolated: a round can never spend another round's chips, even in the same chip.

### 7.3 Lifecycle

1. **`PitBook.recordClose(ticker, day, report)`**: `oracle.verifyCloseAt(ticker, closeTs(day), report)`
   (the print covering 16:00:00, up to `closeMaxLag` late) once that instant has passed, on a weekday for a
   `NYWeekdays` ticker and on any day for an `EveryDay` ticker (skipped days included: a day the book sits
   out still has a close). Either source is accepted (for a keeper print the ticker needs an aggregator,
   section 4). The ticker's registration must be in force.
   - **Replacement.** A trustless print replaces a keeper close and is final; nothing replaces a trustless
     one. A keeper print replaces a keeper close only while the guardian's dispute of it runs (step 5),
     only once per close, and only when it differs from the recorded close by more than the oracle's
     `boundBps` for the ticker (`ReplacementRefused` otherwise). Two valid keeper prints for one instant
     exist only when signers equivocated; the rule keeps whoever holds the second one from moving the
     close by a band on a whim (a band is a quarter sigma, 50 bps at 2%) and from trading replacements
     back and forth until the window ends.
   - **Who and when.** Anyone, until 3 days after the close's instant, and never for a day before the newest
     recorded close (`CloseTooOld`). The owner is exempt from both limits, to seed a ticker or fill a gap.
     A close first recorded more than 12 hours after its instant (`MISSED_CLOSE`) is late: it is the next
     round's start price and steps the variance, but it settles no round (`closeState` shows none), since
     from that instant on the day's rounds can be voided. A missed close is final.
   - **Variance.** The EWMA moves only on a real step: `day` is a day a round after the newest recorded
     close could have (at most 6 calendar days later, every day in between that would have had a round
     skipped or missed), the close is recorded inside the 3 day window, and the stock token's multiplier
     is the same as when the close before was recorded (the book keeps it with every close; a split or
     another corporate action changes it, and then the close is stored without a step). The observation is the squared log return divided by the trading days it spans (`1 + k`,
     as for sigma above) and capped at `(4 sigma)^2`, sigma the variance's own before the step: one jump
     moves the variance by a bounded factor. Weekends are inside every Monday step. Any other
     close is stored, and may become the newest, without touching the variance. A replacement of the
     newest close redoes its step from the stored pre-step variance. Nobody can walk the variance by
     choosing which days to record: a close after a missed day can be recorded only once the
     missed day's close is a day old, and it then spans both days.
2. **`openRound(ticker, chip, day)`** (anyone): requires not paused, a registered ticker whose registration
   is in force, a day that is not skipped (and a weekday, for `NYWeekdays`), now before the cutoff, the
   newest recorded close being the one the round starts from (at most 6 calendar days before `day`, every
   day in between that would have had a round skipped or **missed**: its close not recorded 12 hours after
   its instant, `MISSED_CLOSE`), so only the next round can open, the house's previous round `Final` or
   `Void`, the chip allowed. A previous round that is still `Open` because its close was missed (no close
   recorded 12 hours after it) does not block the house: `openRound` voids it first, exactly as step 7
   would void it 24 hours after its close, so a missed close costs that round and not the next day's as
   well. **A round may be opened as soon as that close is
   recorded and the previous round is over**, and it trades from then on in the windows of its clock: the
   keeper opens it right after it finalized the round before. The house therefore goes from one round into
   the next; LP deposits and withdrawals queue during a round and the vault processes them at the roll, in
   `pullRoundCapital` (section 5). Then: pull the house capital into the hook
   (`vault.pullRoundCapital(house, hook)`; `L` is what arrived, by balance difference), require
   `L >= minCapital * 10^decimals`, store `math.openLnInv(sigma)` for the house and check the depths
   (`math.depths`). `S0 = closePrice[lastCloseDay]`, `sigma = sqrt(varWad)`. The clock and the menu are
   `book.openTerms`' and are frozen with the rest. No contract is deployed: the tickets are ids of the
   hook. An opened round cannot be cancelled. Gas: about 1.06M for the first round of a house, 0.84M
   for the next day's, for any menu (`test/integration/Gas.t.sol`).
   **`router.openAndCommit(ticker, chip, day, ...)`** opens the round when nobody has yet and commits
   the caller's trade in the same transaction, so the first player of a quiet house opens it.
3. **Trade.** `router.commit(round, product, isBuy, shares, limit)` (payable) escrows chips (`limit` =
   the most the user sends in total for a buy) or the product's tickets (for a sell, moved by
   `hook.pull` with no approval; `limit` = the least proceeds). `product` is the index in the round's menu; an index the menu does not have reverts with
   `UnknownProduct`.
   Requires the instant the commit is priced at, `now + fillDelay`, to be inside a trading window of the
   round's clock (`OutsideTradingWindow` otherwise): with the default fill delay of 2 s the last commit
   of the after-hours is made at 19:59:57, the first of the pre-market at 03:59:58, the last of the day at
   15:49:28. Also
   `shares >= minTrade` of the round (default one whole token; dust is refused at commit), and
   `msg.value` equal to the round's fill fee (below; `WrongFillFee` otherwise). A commit cannot be cancelled.

   **Fill fee (the trader pays for the fill).** A fill costs about 1.18M gas (1.53M for the first fill
   of a round) and somebody has to send it. Every commit therefore carries the round's `fillFee` in the
   chain's native coin (ETH): a frozen parameter of the round, default 0.0001 ETH, owner-bounded from 0 to
   0.01 ETH; 0 switches it off. A sell commit carries it too.
   The router holds it with the commit and pays it out exactly once:
   - to **whoever calls `fill`** for that commit, when the fill ends in a trade and when it ends in a
     refund (a rejection by the hook, or the commit's own limit): the filler did the work both times, and a
     commit that could never fill costs its sender the fee, not the filler the gas;
   - back to **the trader**, when nobody filled within the window and the commit is refunded by `refund`.
     Whoever calls `refund` earns nothing.
   A `fill` that reverts pays nobody and leaves the fee with the commit.

   The payment cannot be blocked or reentered. The commit is closed first; the transfer comes last, under
   the router's lock, with 100,000 gas and without copying return data; and if the receiver does not take
   it (its `receive` reverts or burns the gas) nothing reverts: the amount is credited in
   `ethOwed(receiver)` and the receiver pulls it with `claimEth(to)`. So a filler contract that refuses
   coin still fills, and a trader contract that refuses coin can still be refunded. At every moment the
   router's native balance equals the fill fees of the pending commits plus the sum of `ethOwed`. The fee
   never touches the chips, the round's books or the oracle fee. `FallpitLens.quote` returns the fee to
   attach. Known property: the fee goes to whoever's fill lands, so on a chain with a public mempool a
   copied fill could take it from the keeper; the trade is the same either way (one print, one price).

   **Fill order.** One print prices every instant it covers, so commits of one round made in different
   seconds can still fill at one price. They fill in commit order: every commit records `prev`, the round's
   commit before it when the fill windows of the two overlap, and `fill` reverts with
   `EarlierCommitPending(prev)` while that one is pending and its window is still open. A filler therefore cannot place a buy before someone's commit and a sell after it; a
   sandwich needs a commit placed ahead of the victim's, which an FCFS sequencer with a private mempool
   does not offer. An earlier commit that cannot fill is refunded by `fill` (a rejection) and lets the next
   one through; one that nobody fills holds the next one only until its own window ends (fill instants
   only grow and all commits of a round have one `refundDelay`, so it ends first), and then it waits for
   `refund` and holds nobody.

   **`router.fill(commitId, report)`** (anyone): the fill is priced at `t = commitTs + fillDelay` (default
   2 s, never below 2). It can be executed only while `t <= now <= t + refundDelay` (default 30 s, bounds
   10 to 120); `router.refund(commitId)` returns the escrow only after that window. The two windows never
   overlap, so an unfilled commit is an option on the price for at most `refundDelay` seconds.
   The router closes the commit and calls its own `execute(commitId, report)` inside a `try`. For a buy,
   `execute` sends the whole escrow to the hook and passes what arrived as the limit; then it calls
   `hook.fill(roundId, product, isBuy, shares, limit, user, t, report)`. The hook:
   - rejects a round that is not open (`NotOpen`), more than `maxFill` shares (`Cap`), a buy that would
     take a floor over its product cap (`ProductCap`, 7.2), and a fill after its window (`FillExpired`);
   - verifies `(price, ts, trustless) = oracle.verifyAt(ticker, t, report)` and requires the print to be of
     the round's fill source (`WrongFillSource`);
   - asks the book for the round's clock at the print, `(rho, tradable) = book.clockAt(clock, ts)`, and
     rejects a print made outside every trading window with `Window`, a refundable rejection (the print
     for `t` can be up to `maxLag` later than `t`, so a commit made in the last seconds of a window can
     end this way);
   - computes `sd = sigmaEff * sqrt(rho)` (`sigmaEffOf(roundId)`: the round's sigma, or the learned one), `gNew = min(g, max(sqrt(rho), 0.3))`, `x = ln(price / S0)`;
   - calls `math.fill(v, b0, sigma, ctx, lo, hi, delta)` for the product's run `[lo, hi]` (`b0` derived
     from the house's stored `openLnInv`), stores the new `v` and `g`;
   - takes the print's risk budget (`book.takeRisk`; a fill over it is rejected with `Cap`; hook
     DESIGN.md section 18);
   - applies the minimum price and the fees (7.4), the limit, the solvency check and the loss limit (7.5);
   - on a buy checks that its chip balance covers `chipOwed + limit` (`ChipShort` otherwise, not final),
     mints the tickets to the user and sends `limit - cost` back to the user; on a sell burns the escrowed
     tickets from the router and pays the proceeds to the user.

   **Refunds.** `fill` turns exactly one revert shape into a refund of the escrow: the hook's
   `FillRejected(reason)` with a reason from `Limit` to `ProductCap` (`Limit`, `Cap`, `Solvency`,
   `Window`, `NotOpen`, `LossLimit`, `ProductCap`). Everything inside `execute` is rolled back, so the
   escrow is still in the router. The per-fill cap, `NotOpen` and `ProductCap` are decided before the
   oracle is asked, so they refund with any report. Anything else (a report that is not the print for `t`,
   an oracle failure, `ChipShort`, out of gas) reverts the whole `fill` and leaves the commit pending, so
   a filler cannot force a refund. ETH
   sent with `fill` is the filler's own: it pays the oracle's update fee and returns to the filler when the
   fill ends in a refund (through the same payment as the fill fee, so it too is credited in `ethOwed` if the
   filler does not take it). The fill fees the router holds are never used for the oracle.
   The escrow is measured by balance difference and must equal what was sent (`BadEscrow` otherwise: no
   fee-on-transfer chips, section 6). Should a chip start to tax after the commit, the cost of a buy must
   fit in what reached the hook, or the commit refunds (`Limit`).
4. **`settleRound(house, day)`** (anyone, once the close is recorded): the band of the close is
   `bandOf(ln(close / S0))`; a product wins when its run contains that band (`winners` is a bit mask over
   the product indices). Records the payout owed: the sum of the supplies of the winning products.
   Status `Settled`. It can run again only when the recorded close changed (a trustless print replaced a
   keeper print).
5. **`finalizeRound(house, day)`** (anyone): immediately if the close is trustless, otherwise after
   `challengeWindow` (default 900 s, bounds 300 to 3600) from the first settlement and after the dispute
   of the close, if there is one. The window is short because the next round of the house opens only when
   this one is final, and trades in the after-hours from then on. During the window anyone may replace
   the close with a trustless print (step 1) and settle again, and the **guardian** may
   `PitBook.dispute(roundId)`: every round on that close (every house of the ticker) then finalizes only
   from `DISPUTE_WINDOW` (one hour) after the close's instant, 17:00 New York, and until then the close
   may be replaced as step 1 says. A dispute must come before that instant (`DisputeNotAllowed` after it):
   a close settled after about 16:45 cannot be disputed in practice.
   After that the rounds finalize on the latest close. The guardian cannot void a round, settled or not:
   a guardian able to void a settled round would make every bet of a partner a free option.
   `finalizeRound` reverts with `CloseChanged` until the round is re-settled on a replaced close. Keeps
   `payoutOwed` in the hook, moves the protocol's fees to `protocolFeesAccrued`, sends the rest to the
   vault (`vault.returnRoundCapital`). Status `Final`.
6. **Redeem.** After `Final`, `router.redeem(id, amount)` (or `hook.redeem(id, holder, amount)` by the
   holder) burns tickets of a winning product for 1 chip each: no oracle, no fee, no deadline. A ticket of
   a losing product cannot be redeemed. The ticket is the claim: whoever holds it redeems it.
7. **Void.** A round is voided by anyone when it is still `Open` with no recorded close 24 hours after its
   close, and by `openRound` of its house's next round from 12 hours after its close (step 2). Nothing
   else voids a round.
   **The house comes first:** it gets back the capital it brought, as far as the round still holds it. The
   outstanding tickets share what the round holds above that, pro rata to their cost basis, each capped at
   its cost basis (fees included). Protocol fees of a void round are cancelled. So a void never pays house
   capital to anyone: chips that sellers already took out are not owed again to the holders who remain, and
   traders as a group get back exactly what they as a group still have in the round.
   - **Cost basis.** `premium[i]` is what buyers paid for the outstanding supply of product `i`. A sell
     removes the larger of the sold tickets' average cost and the chips the sell is paid.
   - **Refunds are per ticket, not per buyer.** Tickets of one id are fungible and there is no per-buyer
     ledger: every holder gets the same refund per ticket, whatever each of them paid. A late cheap buyer
     shares the refund of those who bought dear (by design).
   - After a void every ticket of product `i` redeems for `premium[i] / supply[i]`.

### 7.3.1 Router sessions (one-tap trading from the user's own address, any wallet)

A user lets a key (a session key the app keeps in the browser) sign orders for them, and anyone relays
those orders. A relayer pays the gas and the fill fee, which it earns back by filling. So
the user needs no popup per trade, moves no coins first, and needs no ETH.

- **EIP-712 domain:** `{name: "Fallpit Router", version: "1", chainId, verifyingContract: router}`.
- **Grant:** `SessionGrant(address user,address key,uint64 expiry,uint256 maxPerOrder,uint256 nonce)`,
  signed by the user (EOA, or ERC-1271 for a smart account) and submitted by anyone with
  `grantSession(grant, signature)`.
  - `expiry`: at most `MAX_SESSION` (7 days) ahead.
  - `nonce` must equal `sessionNonce(user)`.
  - Each grant digest works once, so a revoked session cannot be revived with its old grant.
- **Ending sessions:** `revokeSession(key)` ends one session; `bumpSessionNonce()` ends all of them. The
  user calls either directly.
- **Order:** `Order(address user,bytes32 roundId,uint8 product,bool isBuy,uint256 shares,uint256 limit,uint64 deadline,uint256 nonce)`,
  signed by the key and submitted by anyone with `commitWithSig(order, key, signature)` and
  `msg.value = fillFee`. It is checked as follows:
  - the session is live (not expired, its nonce current);
  - `deadline` has not passed;
  - the order's `nonce` is unused (a bitmap per user, so any order is fine);
  - the amount at risk (a buy's `limit`, a sell's `shares`) is at most the grant's `maxPerOrder`.
- **The commit is the user's commit, exactly as `commit` would make it.** Chips are escrowed through the
  user's own approval to the router; tickets and proceeds go to the user; the same fill instant, `prev`
  order, windows and refund reasons apply. A sell escrows the user's tickets with `hook.pull`, as a
  plain sell does. One difference:
  - **Fill fee.** It goes back to whoever paid it (`feePayerOf(commitId)`), not to the user, when nobody
    fills, and also after a fill or a refund inside `fill` unless the payer filled it. Otherwise anyone
    (the user too) could drain a relayer by filling relayed commits first.
- **Worst case:** a leaked key can only trade the user's chips (each order at most `maxPerOrder`) and
  tickets on Fallpit until the session ends. It can never send anything anywhere else.
- **`redeemFor(user, id)`:** redeems all of `user`'s tickets of `id` for them, and anyone may call it. The
  payout always goes to `user` (the hook pays the holder it is given and accepts the router on any
  holder's behalf), so a caller can only make a user collect what is theirs.

### 7.4 Fees (all inside the hook)

- Base rate `f(ts)`: `baseFee` (2%) until `feeRamp` (120 minutes) before the close, rising linearly (rounded
  up) to `closeFee` (5%) at the close.
- Vega fee per share: `vegaFee * fill.vega` with `vegaFee = 0.10e18`. In simulation a lower vega fee
  lost the house 0.2 to 0.5 points a day and worsened every tail, and a higher one priced the centre floor
  under 4.4x.
- Buy: `amount = max(ceil(math.amount), ceil(shares * minPriceWad))` (at least one chip unit: the
  minimum price of 7.2); the trader pays `amount + ceil(amount * f) + ceil(shares * vegaFee * vega)`.
  The vega of a product is taken from the two edges of its run (a run that reaches an end of the ladder
  has one). Sell: `amount = floor(math.amount)`; the
  trader receives `amount` minus the same fee, the fee capped at `amount`.
- Fees stay in the round's `held`; `floor(fee * protocolFeeBps / 1e4)` (default 1000 bps) of each fee is set
  aside for the protocol and sent by the permissionless `collectProtocolFees(chip)` to the fee recipient.

### 7.5 Solvency, the loss limit and complete sets (pooled, checked after every fill)

If the close lands in band j the round pays the outstanding supply of every product whose run contains
j. With the fill applied, the round's **cushion** is

```
cushion = chips held for the round - protocol fees - max over the 40 bands (sum of the supplies over the band)
```

what the house has left if the close lands in the worst band (`PitMath.maxPayout`, a difference array
over the bands). Two rules
(`PitMath.postFillCheck`, the same code in the hook and in the lens):

- **Solvency, every fill.** `cushion >= 0`. A fill that would break this, or a sell that would pay more than
  the round holds, is rejected with `Solvency`. The house can lose what it brought to a round, never more.
- **Loss limit, buys only.** A buy must leave `cushion >= capital * (10000 - lossLimitBps) / 10000` (compared
  cross-multiplied, so the floor is never rounded down). A buy that would leave less is rejected with
  `LossLimit` and the router refunds it like any other final rejection. `lossLimitBps` is a frozen
  parameter of the round (default 3000, owner-bounded 1000 to 10000; 10000 leaves only the solvency
  rule). In simulation 3000 cost nothing in mean or refusals in ordinary conditions and, against 5000,
  cut the worst day from -42% to -32% of the capital at a vol error of 30%, and a whipsaw gang's take
  from 50% to 30%.
  **A sell is exempt:** it only has to keep the round solvent, so a holder can always exit, also while buys
  are blocked. The limit is the round's, not a trader's: it blocks only buys that deepen the worst band
  (a buy of a product that pays in other bands still fills).

Before both, on a buy, comes the **product cap** of 7.2 when the round has one (the default has none):
a floor's own supply is at most `floorCapBps` of the capital.

**Complete sets.** A set of products that covers every band exactly once (on the default menu: HIGHER +
LOWER; the eight floors; the four lower floors + HIGHER; LOWER + the four upper floors) pays exactly one
chip whatever the close. Bought at one print it costs at least one chip before any fee: the cost function
is translation invariant (one more ticket in every band costs exactly one chip), the buys telescope, and
every rounding step goes against the trader. Measured on the real stack over the four sets, five oracle
prices from -3.5 to +3 sigma, three times of the round and sizes from one ticket to the per-fill cap: the
least margin of a set over its payout, before fees, was 3.4e-12 chips, and fees come on top
(`test_floors_completeSets_neverCostLessThanTheyPay`, and a fuzz on a book other traders have skewed).
Sold back, a set never returns more than its payout. Sets bought at different prints are not covered by
this: buying one half at a low and the other at a high is a bet on the oracle's path, the same as trading
one product, and is what the loss limit is for.

**What the caps and the limit do** (measured on the real stack, capital 1,000,000, sigma 2%, the
defaults: alpha 0.2, loss limit 30%, no product cap; oracle at the previous
close, lots of the 2% per-fill cap; `test/integration/LossLimit.t.sol`). "Regular" is one minute into
the regular session (rho 0.698), "after-hours" two minutes after the previous close (rho 0.9995):

| One-sided buying of | when | tickets bought | chips paid | lowest cushion | stopped by |
|---|---|---|---|---|---|
| HIGHER, limit 30% | regular | 300% of capital | 302% | 96.1% (after 26% of capital in tickets) | nothing |
| HIGHER, limit 30% | after-hours | 300% of capital | 301% | 95.5% (after 30% of capital in tickets) | nothing |
| floor +1 to +2 sigma | regular | 100% of capital | 91% | 88.4% (after 34%) | the cap's ceiling (a floor may hold the whole capital), at the 51st lot |
| floor +1 to +2 sigma | after-hours | 100% of capital | 90% | 87.7% (after 38%) | the ceiling |
| floor 0 to +0.5 sigma to the ceiling, then HIGHER | regular | 100%, then 60% (test stops) | 94%, then 61% | 91.2%, no lower with HIGHER | the ceiling, then nothing |
| floor above +2 sigma to the ceiling, then HIGHER | regular | 100%, then 60% (test stops) | 86%, then 61% | 84.1%, then 85.4% | the ceiling, then nothing |
| floor +1 to +2 sigma, limit 10% | regular | 16% of capital | 6.2% | 90.1% | the loss limit, at the 9th lot |
| floor +1 to +2 sigma, product cap 10% | regular | 10% of capital | 2.7% | 92.6% | the product cap, at the 6th lot |
| HIGHER, limit 10% | regular | 120% of capital (test stops) | | above 92% | nothing |

So at one oracle price the engine itself never puts more than about 4% of the capital at risk on the
pair (the ticket's price goes to one chip first, and from there every ticket is paid for in full), about
12% on a floor and about 16% on the worst band of the default menu (a far floor and the half of the
pair over it): the exposure of a band is bounded near `alpha` times the capital less what the buyers
paid, which is why the defaults have no product cap and a tight loss limit instead. One-sided buying
alone never reaches
the default limit, and ordinary two-sided flow stays far from it (lowest cushion of a busy simulated
day: 99.0%; of the round in `day.json`, where one floor holds 10.8% of the capital: 91.9%). What the
limit is for is the bad day: the stock whipsaws 8% down and 6% up and a gang buys HIGHER at every low
(at the minimum price: four sigma down it is a lottery ticket) and sells it at every high. Without the
limit that takes about 95% of the house's capital; with the default limit buys are refused once the
cushion is at the floor, every sell still fills, and the house keeps 70.6% (55.5% with a 50% limit;
`test_attack_whipsaw_lossLimitStopsTheBuying_houseKeepsSeventyPercent`). Simulation agrees: the
whipsaw gang takes exactly the limit on every menu, and `lossLimitBps` is the lever. The limit also bounds what a broken pricing engine can give away on the pair at 30%, and on a
floor the minimum price makes every free ticket cost two hundredths of a chip
(`FallpitBrokenMathTest`). These figures are for one oracle path each; they are not a simulation of
extended-hours trading (section 7.2, "Not validated").

**What a floor that wins costs.** With no product cap a floor is bounded by the engine like the pair:
bought one-sidedly it costs its buyers about one chip a ticket once `alpha` times the capital is
outstanding, so a floor that wins pays out what its buyers mostly paid in. The exposure is at the start
of the buying: the far floor of the default menu filled with 100,000 tickets at the previous close
brings in about 7,000 chips (0.7% of the capital, the first lot at the minimum price) and pays 100,000
if the close lands above +2 sigma. In the round of `day.json` the popular floor (0 to +0.5 sigma) ends
the day with 10.8% of the capital outstanding and does not win. In simulation a far floor is quoted
about 28x against a fair 42x, so the house's edge on long shots is large on average, and the biggest
single payout in 4,000 simulated days was 8% of the capital.

**What the limit does not do.** It is checked on buys. A sell takes chips out of the round, and in the
bands where the sold ticket loses that lowers the cushion. As long as only one product is involved this
cannot take the cushion under the floor (a sell is paid at most one chip per ticket and removes one chip of
payout per ticket). With positions on two sides it can: a gang that parks a cheap position on one side and
rides oracle swings on the other took the cushion to 48% of the capital on two far floors (a tenth of the
capital parked, a tenth ridden per swing, five swings) and to 43% on the pair, measured with the limit at
50% and a product cap of 10%, and the house lost 52.3% and 56.5% when the day ended on
the parked side
(`test_lossLimit_knownLimit_sellsOnAnotherTokenCanTakeTheCushionBelowTheFloor`,
`test_lossLimit_knownLimit_onThePair_sellsTakeTheCushionBelowTheFloor`). Once the cushion is under
the floor every buy that would not raise it back is refused, so the damage does not grow through new
positions. `lossLimitBps` is therefore the most a round's buyers can put at risk at any one time, and close
to the most the house loses on a bad day, not a hard cap on the day's loss; the hard cap is solvency. Making
sells respect the floor would give the hard cap and take away the exit.

**What the product cap costs, when a round has one.** Whoever holds a floor's whole cap keeps everybody
else out of that floor until they sell. With the cap at a tenth, cornering
the far floor of the default menu at the previous close cost 6,997 chips on a capital of 1,000,000
(0.7%); unwinding at the same price returned 5,585. It blocks no other product (the
half of the pair over the same bands included), a buyer who tries is refunded (and pays the fill fee,
which goes to the filler), and the lens reports `ProductCap` beforehand
(`test_attack_capGriefing_onAFloor_locksOnlyThatFloor_atACost`). With the default of no cap there is
nothing to corner.

### 7.6 Tickets

Every product of a round is an ERC-6909 id of the hook: `id = uint256(roundId) | product`
(`tokenId(roundId, product)`; `tokenRef(id)` splits it again). The hook mints a buy's tickets to the
user and burns sold and redeemed ones; `getSupplies(roundId)` is the outstanding supply the hook uses for
solvency at every point. Every id has the name "Fallpit ticket", the symbol `PITTIX` and the decimals of
its round's chip, so one winning ticket pays one chip. `hook.pull(from, id, amount)` moves tickets into
the router's escrow with no allowance; only the router may call it, for its own caller or a
session-signed user (7.3.1). Tickets sent to the hook or to the router outside that escrow belong to
nobody.

A product's price range is `low = S0 * exp(edge(lo - 1))` (zero when the run starts at band 0) and
`high = S0 * exp(edge(hi))` (the largest uint256 when the run ends at band 39), with
`edge(m) = (m - 19) * sigma / 4` as in the engine (`PitMath.bounds`, returned by `FallpitLens.market`). A
product wins when `low <= close < high`; the outcome is decided on the band of `ln(close / S0)`, so apps
should show the lens's `low` and `high`, rounded to a wei.

### 7.7 Events

`RoundOpened` (with the menu word), `Filled` (with the product index), `RoundSettled` (with the `uint16`
mask of winners), `RoundFinalized`, `RoundVoided`, `Redeemed` (with the ticket id), `ProtocolFeesCollected`,
`SigmaEffSet` and the ERC-6909 `Transfer`, `Approval` and `OperatorSet` of the tickets (hook);
`Committed`, `Filled`, `Refunded`, `FillFeePaid(commitId, to, amount, sent)` (`sent` false when the
amount went to `ethOwed`), `EthClaimed`, the session events, `BoughtWithEth` (router); `CloseRecorded`,
`TickerRegistered`, `DefaultParamsSet`, `SkipSet`, `SkipAfterHoursSet` and the role events (book).

### 7.8 Roles and their powers (nothing else)

| Role | Powers | Limits |
|---|---|---|
| PitBook owner | register a ticker (seed variance, clock, clock weights, trading windows, fill source); reseed a registered ticker (variance, clock weights, trading windows, fill source; never the clock); set `skip[ticker][day]` and `skipAfterHours[ticker][day]`; pause the opening of new rounds; name the guardian and the fee recipient; set the default parameters of future rounds; record past closes | A **new ticker**, a **reseed**, a change of the **default parameters** and a new **guardian** take effect 24 hours after they are announced; `pendingReseed` (a pending registration included), `pendingDefaultParams` and `pendingGuardian` show what is waiting. Nothing can be done with a ticker before its registration is in force: no close, no round, no house (the vault asks the book's `supported`). `skip` only for a day whose close is at least 24 hours away. `skipAfterHours`, the pause and the fee recipient are immediate (the first two only remove trading or opening), and reach a round only when it opens. Past closes never move the variance. Two-step ownership transfer |
| Vol keeper | `FallpitHook.setSigmaEff(roundId, sigmaEff)` for an open round, once per 300 s: the sigma its remaining sd and vega use (section 10). Named by the PitBook owner (`setVolKeeper`), in force 24 hours later; zero means nobody | clamped by the book to at most 10% from the sigma in force per update, 0.8x to 1.5x of the round's sigma, all rises of a round together at most 1.5x; a colluding vol keeper can still pay a trader about 1.8% of capital once per round, so it is a trusted role (zero by default); never touches the bands, the opening depths, the config or funds; a commit's limit protects its trader |
| Guardian | `PitBook.dispute(roundId)` inside the challenge window of a `Settled` round whose close is not trustless, and before one hour after the close's instant: the rounds on that close finalize only one hour after its instant (`DISPUTE_WINDOW`, 17:00 New York), and until then the close can be replaced (7.3 steps 1 and 5) | cannot void, settle or replace anything itself; powerless when the close is trustless; a dispute costs every house of the ticker about 45 minutes of the next round's after-hours (the next round opens only once this one is final, at 17:00 instead of about 16:15), so the guardian is trusted for liveness, not for outcomes |
| PitOracle owner | per-ticker sources and limits, source on/off, signer set and threshold | sources are set once; signer changes, every change of a configured ticker and a source's switch-off for closes wait 24 hours, cancellable; the switch-off reaches only closes 24 hours or more after it; only stopping fills (an emergency brake) and switching back on are immediate (section 4) |
| Keeper signers | at `threshold`: any print inside the Chainlink bound | section 4 |
| ChipGuard owner | the trust lists and flags | holds no funds; cannot affect existing houses' deposits, withdrawals or claims |
| CommunityTreasury owner | move a non-chip token out of an inbox | never the chip leg |
| Router deployer, book deployer | `setHook` once each | frozen afterwards; the deploy renounces the router's deployer right after `setHook` |
| PitBook owner, on the router | `setEthPool(chip, ...)`: the hookless ETH/chip pool of `commitWithEth` | only pools with no hooks; the app quotes the pool it swaps on |
| Hook, vault, router, math, lens | no owner | |

No role can change an open round's config, and no role can move user, LP or endowment funds. The one input to
an open round is the vol keeper's learned sigma (`setSigmaEff`, section 10), inside the hook's clamps. Parameter
bounds enforced by the book: `0 < alpha <= 0.79`, `0.5% <= baseFee <= 10%`, `baseFee <= closeFee <= 20%`,
`vegaFee <= 1`, `feeRamp <= 6.5 h`, `300 s <= challengeWindow <= 3600 s`, `2 <= fillDelay <= 60`,
`10 <= refundDelay <= 120`, `protocolFeeBps <= 5000`, `0 < maxFillBps <= 10000`,
`0 < minCapital <= 1e15`, `alpha * minCapital >= 1e15` (so `openDepths` accepts every round that passes
`minCapital`), `1e12 <= minTrade <= 1000e18`, `minCapital * maxFillBps / 1e4 >= minTrade` (so the smallest
round can still trade), `1000 <= lossLimitBps <= 10000`, `fillFee <= 0.01 ETH`, `floorCapBps <= 10000`
and `minCapital * floorCapBps / 1e4 >= minTrade` (so every floor of the smallest round can still trade),
`minPriceWad <= 0.2`, and a well-formed menu: 2 to 12 products, every run `lo <= hi <= 39`, nothing
stored above the last product (runs may overlap, repeat, and leave bands uncovered). Variance in
`[0.005^2, 0.15^2]`. Clock weights sum to 10000 basis points with at least 2500 in the regular session;
`EveryDay` takes `(0, 0, 0, 10000)`; all zero at registration means the defaults (`defaultWeights`). The
`windows` mask of a `NYWeekdays` ticker is 8 to 15 (the regular session always in), zero meaning the
default 13; `EveryDay` takes zero only.

Defaults: `alpha 0.2`,
`baseFee 2%`, `closeFee 5%`, `vegaFee 0.1`, `feeRamp 120 min`, `challengeWindow 900`, `fillDelay 2`,
`refundDelay 30`, `protocolFeeBps 1000`, `maxFillBps 200`, `minCapital 1000`, `minTrade 1e18`,
`lossLimitBps 3000`, `fillFee 0.0001 ETH`, `floorCapBps 10000` (no product cap), `minPriceWad 0.02`, and
the menu of 7.2. `minCapital`
stays 1000: `alpha * minCapital` is 2e20 against the bound of 1e15, and the smallest round opens
(`test/integration/MinCapital.t.sol`).

### 7.9 Reentrancy

Hook, router and vault each have a transient-storage lock on every state-changing entry point. The
router's `execute` accepts only the router itself under that lock, and its `unlockCallback` (the ETH swap
of `commitWithEth`) only the PoolManager under that lock. The router's
payments of native coin (fill fee, a refunded fill fee, a returned oracle fee) are made last, with the
commit already closed, inside that lock, and never revert (7.3); `claimEth` is locked too.

### 7.10 Tests

- Unit and attack tests of the hook side (`test/hook`).
- The whole real system (`test/integration`): full rounds on the keeper-signed and the Pyth path with cash
  conservation to the unit, a 1% tax chip refused at every entry point and a chip that starts to tax
  mid-round, two days rolling one house, losing days, every void path, the fill source policy, launchpad
  fees into a house; the loss limit (`LossLimit.t.sol`); the fill fee (`FillFee.t.sol`: paid to the filler
  on a fill and on a refund, returned on a timeout, wrong value, a filler that reverts on receive, one that
  burns its gas, one that reenters, a fee of zero); the attack suite against the real math and oracle; a
  stateful invariant fuzz with fail-on-revert (chips conserved, and the router's native balance equal to
  pending fill fees plus `ethOwed`); a day-level differential test against the Python reference; fork tests
  on 46630 and 4663 against the live Pyth contract, with the mainnet delays; the deploy scripts; the gas of
  a fill, a commit and an open (`Gas.t.sol`).
- The round clock: `test/hook/PitClock.t.sol` (both clocks to the second at every edge, Friday to Monday, a
  skipped day in between, both daylight-saving switches, the after-hours flag, the windows mask bit by
  bit and with the nights switched on (weekday nights only), rho never rising and exact at the edges, the
  depth scale never rising, the book answering with the library's values);
  `test/integration/ExtendedHours.t.sol` (a stock round traded in all three windows with cash
  conservation, commits and fills at every window edge, the flag, Friday to Monday, a stock traded
  through the night on the windows mask 15 next to one that stops at 20:00, an every-day asset
  through four consecutive daily rounds over a weekend with LP queues processed at the roll); the day-level
  differential test trades all three windows; the invariant fuzz opens each round as the one before ends
  and trades all three windows.
- The menu: `test/hook/FallpitMenu.t.sol` (the menu word and its bounds, the 24 hours and the freeze,
  the price range of every shape of run, the product cap and the minimum price with refunds, whole rounds on
  six floors and the pair, on a six-product threshold menu, on the pair alone, on twelve
  products and on a menu that does not partition, the lens's `market`); `test/integration/Floors.t.sol`
  on the real stack (exactly one floor wins and the books close for a close in every floor, a floor and
  the half of the pair over it are both paid, the cap and the minimum price, complete sets never cost
  less than they pay, a synthetic half costs what the half costs, prices of a partition sum to one, other
  menus). Tests run on the default menu or, where a scenario needs three products that are each dear at
  one end of a swing, on the six-product threshold menu (each such test says so). The stateful suites run
  the default menu, four other fixed menus and
  menus drawn at random (the system suite draws a new one every day), and count the worst band directly
  against the hook's difference array. The day-level differential test is a floors day: 96 trades on all
  ten products in all three windows, one floor bought to 10.8% of the capital with nothing refused (no
  product cap, and the loss limit at 30% is out of reach of one day's flow at alpha 0.2), fifteen buys at the
  minimum price, the cushion compared after every fill.
- The defaults: the default menu opens a round on `minCapital` at alpha 0.2
  (`test/integration/MinCapital.t.sol`), the loss limit binds at 30% in the whipsaw scenario and the
  house keeps 70% (`test/integration/AttacksTrading.t.sol`), no product cap refuses a buy under the
  defaults and the lens flags a far floor `dead` when the price sits three sigma away
  (`test/integration/Floors.t.sol`).

## 8. Keeper report formats

- **Pyth:** `0x01 || blob`, `blob` = `binary.data[0]` (hex decoded) of
  `GET https://hermes.pyth.network/v2/updates/price/<t>?ids[]=<feed id>` (the first update at or after `t`).
  Send `getUpdateFee([blob])` as `msg.value`.
- **Pay.** A fill earns its sender the commit's fill fee (7.3), also when the fill ends in a refund. The
  keeper needs no allowance and no registration: the fee is paid to `msg.sender` of `fill`. A keeper that
  is a contract must be able to receive native coin within 100,000 gas, or pull its fees with `claimEth`.
  Measured gas of a fill with a keeper print (`test/integration/Gas.t.sol`): about 1.18M, 1.53M for the
  first fill of a round. The default fee is well above that at the chain's 0.02 gwei;
  if gas rises past the fee the owner raises `fillFee` (24 hours ahead) or the keeper fills at a loss.
- **Keeper:** `0x02 || abi.encode(Print{ticker, price, ts, prevTs}, bytes[] signatures)`. One print per ticker
  per second whenever a round of the ticker trades (the after-hours and the pre-market of a stock round
  that is open, any hour of an every-day round), in every regular session, and after each close until the
  print for 16:00:00 exists (up to `closeMaxLag`, 300 s): `ts` is the current second, `prevTs` the `ts` of
  the previous print of that ticker, `price` in WAD. The first print after a pause starts where the last
  one ended, so it is the print for every instant in between that is at most `maxLag` old, and the close
  when 16:00:00 is in its interval and it is at most `closeMaxLag` late. Signatures in ascending signer order.
- On testnet the keeper also copies each new round of the mainnet Chainlink feed into the ticker's
  MirrorFeed (`push(answer, updatedAt)`) and the stock token's multiplier into its stub.
- The close of day `D` is the print covering `closeTs(D)` (16:00:00 New York) at most `closeMaxLag` late,
  recorded with `recordClose` within 3 days, before 64 newer feed rounds exist for a keeper print. An
  every-day ticker has one every calendar day. Right after it finalized a round the keeper opens the
  house's next one. A holiday or an early close (the keeper's NYSE table) has no close: the keeper records
  none and opens no round for it.
- **Extended hours, what the sources do (not covered by these tests).** A `TrustlessOnly`
  stock is priced by its Pyth feed. The TSLA and QQQ feeds publish 24/5, nights included (Sunday about 19:55 to Friday 19:59:58 New York), which is what the overnight bit
  of the windows mask is for; whenever a feed does not publish, a commit made then has no print and is
  refunded by time, fee included. A keeper print must be within the band of the Chainlink round in force; the stock feeds run
  24/5 and move on 0.5% steps with no heartbeat off-hours, so a fast move in thin hours leaves the band and
  the prints stop until the feed follows. All of this fails closed (no print, no fill).

## 9. Testnet contracts (`src/testnet/`)

- **MirrorFeed**: an AggregatorV3-shaped feed (`decimals`, `latestRoundData`, `getRoundData`, phase-1 round
  ids, zeros for a missing round) whose rounds one keeper address pushes, copying the mainnet Chainlink feed.
  Rounds are append-only, their times never go back and are never in the future. Robinhood Chain testnet has
  no stock feeds; this lets PitOracle bound keeper prints there as on mainnet. Whoever holds the pusher key
  decides the bound: testnet only. **On testnet the 60 bps bound is trust-based**: it holds only as far as
  the pusher copies mainnet faithfully. The deploy script refuses a pusher that is also a keeper signer.
  Testnet prices are signed by the operator.
- **MirrorStockToken**: `uiMultiplier()`, maintained by the same pusher.
- **FaucetCoin**: 18 decimals, `faucet()` mints 1,000 coins per address per 24 hours, `burn(amount)` burns
  only the caller's own balance, no mint after the constructor's initial supply to the deployer, no owner.
- **TestLaunchpad**: a stand-in launchpad for open listing; it answers `getLaunchedToken` in the Pons v2
  shape.

`script/DeployTestnet.s.sol` deploys and wires everything for 46630 (`run()`, then `createHouses()` and
`setUpListing()`); `script/DeployMainnet.s.sol` does mainnet 4663 in one run. `README.md` has both.

## 10. Vol learning and the vol-mix prior

Two parts of the engine adapt to the day's volatility:

1. **House-side intraday vol learning.** The round's `sd` and the vega, never the bands and never the opening depths,
   use `sigmaEff`. The vol keeper computes it from the prints at each minute of the learning
   windows (a stock round's regular session, an every-day round around the clock):
   `sigmaEff^2 = (k * sigma^2 + sum r^2) / (k + u)`, `k = kappa / 390` (kappa 90 by default, an off-chain
   setting), `u` the share of the round's variance the sampled minutes cover (from its clock), which for a
   one-day stock round is `(90 * sigma^2 + 390 * sum r^2) / (90 + minutes)`. It posts it with
   `FallpitHook.setSigmaEff(roundId, sigmaEff)` every 5 minutes when it moved by more than 2%. Only the
   book's `volKeeper` (named by the owner, `OWNER_DELAY` later) may call it, only for an open round, once a
   per 300 s per round; the book clamps each update to at most 10% from the sigma in
   force, to 0.8x to 1.5x of the round's sigma, and all rises of one round together to 1.5x. A fill is priced at the `sigmaEff` in force when it is filled; its limit protects
   the trader from an update between commit and fill. In simulation it gained the house 0.44 points a
   day when volatility was mispriced and cut the worst day from -42.6% to about -9%; it loses a little on
   jump days and on a smooth trend day.
2. **A vol-mixture prior in LadderMath.** The prior of section 3 (3 nodes; in simulation 3 nodes matched 9).

The defaults of section 7 come from the same simulations: alpha 0.2, no product cap, loss limit 30%,
minimum price 0.02, vega fee 0.10.

## 11. Out of scope

Range LPs, a menu per ticker (the menu is one default for all), learned clock weights (the owner sets
them), Universal Router support, markets on a coin's own price, a loss limit that also binds
sells (7.5), a trading halt for an open round (the after-hours flag is read at the open and nothing stops
an open round), a holiday and early-close calendar on chain (the owner marks the days with `skip` a day
ahead), early-close days as rounds with a
13:00 close (they are skipped), an economic validation of trading in the extended hours (7.2).
