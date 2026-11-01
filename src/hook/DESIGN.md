# Hook side: design

Covers `FallpitHook`, `FallpitRouter` and the helpers in `src/hook/`. `SPEC.md` section 7 states the
rules; this document gives the reasons behind them. Section 16 is the floor menu.

## 1. Contract layout

| Contract | Why it exists |
|---|---|
| `FallpitHook` | rounds, fills, settle, finalize, void, redeem, protocol fees; the ERC-6909 tickets of every round (id = round id \| product index); holds the chips of every round. No owner. |
| `FallpitRouter` | commit (also `openAndCommit`, `commitWithEth` and session orders), fill (through its own `execute`), refund, redeem, the fill fee. The only caller of the hook's `fill` and `pull`. |
| `hook/PitBook` | closes, EWMA variance, calendar (`skip`, `skipAfterHours`), the round clock (`clockAt`), default params (the menu among them), owner, guardian and its `dispute`, the vault's gate (`supported`), the vol keeper's bounds (`stepSigmaEff`), the print risk budget (`takeRisk`). |
| `hook/PitClock` | library: the clock of a round (rho, trading windows). Compiled into the book and the lens. |
| `hook/FallpitLens` | quotes (with the rejection the hook would make), a round's whole menu in one call (with the `dead` flag and each product's price range), the all-in cost of a product at three sizes, solvency and loss limit views. |
| `hook/PitMath` | pure pieces shared by the hook, the book and the lens (the menu word, winners, the worst band, the product cap, the post-fill check, the pricing context from rho, fees, a product's price range, the live strike rules and the nearest edge). |
| `hook/RoundLogic` | linked library, run in the hook's context on the hook's storage: the open of a new round (the book's terms, the chip check, retiring the house's previous round, the setup), settle, finalize, void, the book side of redeem, and the rules of a live strike. These run once a round (or a few times), and keeping them out of the hook keeps it under the size limit. |
| `hook/PitBookLogic` | linked library, run in the book's context on the book's storage: the terms a round opens with (`openTerms`), a ticker's registration, the guardian's dispute, and the bounded step of the learned sigma. The book keeps every caller check in front of each call. |
| `hook/PitBookRules` | linked library, pure: the bounds of the owner's settings (default parameters, a ticker's terms, a menu word) and the daily variance step. |
| `router/SessionLogic` | linked library, run in the router's context on the router's storage (`SessionStore`): granting a session, the session key's signed orders, vault actions, listings and cancels, the spending caps, and the EIP-712 digests. The router keeps its reentrancy lock around every call. |

**Linked libraries.** The four libraries hold code that is not on the fill path (opens, settlements, owner
and session calls), so the hook, the router and the book each keep at least 3 KB under the 24,576 byte
limit for later fixes. A call into one costs about 2,600 gas more than the same code inline (a
`DELEGATECALL` and its ABI encoding); a fill makes none of these calls. Every library function that writes
storage is `external` and called with `DELEGATECALL`, so it runs on the calling contract's storage, with its
`msg.sender`, and its events come from that contract. Solidity's library call guard makes a direct call to a
library's state-changing function revert. The deploy scripts deploy each library from the deployer through
the CREATE2 factory (salt 0), check its runtime code against the build and check that each contract links
exactly that address; the deployment record lists every library with its address and code hash.

**Why PitBook is a separate contract.** With everything in one contract the hook is over the 24,576 byte
limit (27,175 bytes when measured). The per-ticker state, `recordClose` and
every owner function are in `PitBook`; the hook reads it through an immutable address (`openTerms`,
`closeOf`, `guardian`, `feeRecipient`) and copies what a round needs when the round opens. Nothing is
weakened: the book holds no funds, the hook has no owner at all, and the book cannot change an open round
(the one exception: its vol keeper may set an open round's learned sigma, `setSigmaEff`, inside the clamps
of `PitBook.stepSigmaEff`; the config stays frozen). Events `CloseRecorded` and the admin events are emitted
by the book.

## 2. Router and hook wiring

The hook's `router` is immutable. The router is deployed first with no hook; `setHook(hook)` can be called
once, only by the router's deployer, only with a contract whose `router()` is this router, and is then
frozen. `deployer` is a storage variable (set at construction, cleared for ever by `renounceDeployer`),
kept from the via-IR build, where a second immutable in the router hit a solc 0.8.26 internal compiler
error. The deploy (`script/FallpitDeployer.sol`) renounces right after `setHook` and checks
`deployer() == address(0)`, so the deploy key keeps no right on the router. `setEthPool` (the hookless
ETH/chip pool of `commitWithEth` for a chip that needs another pool than the default) is then the book's
owner's: the router reads `hook.book().owner()`, so the right follows the book's ownership to OWNER.

The vault and the hook pin each other as immutables. The vault is the deployer's next CREATE; the hook is
created through the deterministic deployment proxy with a fixed salt, so its address follows from its init
code alone and a failed creation can be sent again to the same address (`script/FallpitDeployer.sol`).

## 3. Fill plumbing

- **Tickets.** Every product of a round is an ERC-6909 id of the hook: `id = roundId | product`.
  `roundIdOf(house, day)` is `keccak256(abi.encode(house, day))` with the low byte cleared, so the index
  fits there; `tokenRef(id)` splits an id again. Every ticket has the one name "Fallpit ticket" (symbol
  `PITTIX`) and its round's chip decimals, so one winning ticket pays one chip. The supply and the premium
  of each product are in the round (`getSupplies`).
- **A fill is one call of the router on itself.** `router.fill` closes the commit, then calls
  `this.execute(commitId, report)` inside a `try`. `execute` accepts only the router itself under its own
  lock.
- **Buy.** `execute` sends the whole escrow to the hook and measures what arrived; that is the buy's
  `limit`. The hook checks that its chip balance covers `chipOwed + limit` (a low-level `balanceOf`, so a
  chip's own revert data never comes out of a fill; a short or failed read is `ChipShort`, which is not
  final), prices the fill, mints the tickets to the user and sends `limit - cost` back to the user.
- **Sell.** At commit the router escrows the user's tickets with `hook.pull` (no allowance; only the router
  may call it, for its own caller or a session-signed user). In the fill the hook burns the tickets from
  the router and pays the proceeds to the user. A sell needs no approval.
- **Rejection.** When the hook rejects the fill for good, the `try` catches it: everything inside `execute`
  is rolled back, the escrow is still in the router, and the router refunds it from there.
- **The hook holds the chips.** Capital and premium sit in the hook's own balance. `chipOwed[chip]` is the
  sum of every round's `held` plus accrued protocol fees, and the hook's balance of the chip is always at
  least `chipOwed(chip)`. Chips above `chipOwed`, and tickets
  sent to the hook or to the router outside the router's escrow, belong to nobody: nothing can move them
  out again.
- The hook's `Filled` event reports the chips paid or received and the fee inside them.

## 4. Commits, fills, refunds

- The hook's `fill` takes `user` and the fill instant `t` as arguments and trusts them only because the
  caller is the router, which reads both from its commit record. The report authenticates itself in the
  oracle.
- **Fill window.** A commit can be filled only while `t <= now <= t + refundDelay`
  (`t = commitTs + fillDelay`), and refunded by time only after that. The two windows never overlap, and
  the hook enforces the upper bound itself (`FillExpired`). Without this, an unfilled commit would be a
  free option on later prices (fill at the earlier print if the price moved your way, refund otherwise) for as
  long as it stayed pending. The residual: if no keeper fills for the whole window, the user can still
  choose in the last second. The window is therefore short: `refundDelay` defaults to 30 s and cannot be
  set above 120 s.
- `fillDelay`, `refundDelay` are per-round parameters (frozen at open, owner-set defaults within bounds
  2..60 and 10..120). The floor of two seconds on `fillDelay` keeps the print out of sight when the chain's
  clock and the oracle's differ by a second.
- **Minimum trade.** A commit below the round's `minTrade` (default one whole ticket, frozen at open) is
  refused at commit, for buys and sells. A dust commit costs its sender about 231k gas and the filler a
  full pricing run of about 1.18M; a keeper that skipped dust would leave those commits as options. With the
  fill fee (section 11) the sender of any commit also pays for its fill.
- **Refund classification.** `fill` refunds only on one exact revert shape caught from `execute`: the
  hook's `FillRejected(reason)` with a reason from `Limit` to `ProductCap` (limit, cap, solvency, trading
  window, round not open, loss limit, product cap). Only the hook reverts with it: the coins it calls are
  checked by the chip guard, and the oracle and the book are part of the system. Anything else (wrong report, oracle
  failure, `ChipShort`, out of gas) reverts the whole `fill` and leaves the commit pending, so a filler
  cannot force a refund by feeding a bad report or starving gas. Cap, product cap and not-open rejections
  come before the oracle call, so they refund with any report.
- The cap is checked only in the hook (not at commit), so over-cap commits take the refund path.
- `limit` for a buy is the most the user sends in total; for a sell the least the fill must pay.

## 5. Fee-on-transfer chips: refused

A coin that keeps a part of every transfer is not a chip (SPEC section 6). On the hook
side that means:

- `openRound` asks the chip guard, which never allows a flagged coin.
- `commit` measures the escrow by balance difference and reverts with `BadEscrow` unless it equals what
  was sent, so a tax coin the guard does not know about cannot trade either. (A sell escrows tickets, which
  move inside the hook exactly.)

Defence in depth, for a coin that starts to tax after it was let in:

- On a buy `execute` sends the escrow to the hook and passes what arrived as the limit, so the cost must
  fit in what the hook received; otherwise the commit refunds (`Limit`). The hook's own balance check
  (`ChipShort`) refuses a fill whose chips are not there.
- Every outflow (sell proceeds, change of a buy, redemption, vault return, protocol fees) is the nominal
  amount; the receiver bears the chip's tax. The capital is what arrived when the vault paid in (balance
  difference).

So such a coin can cost its holders and its house the tax, and cannot make the hook's chip balance fall
short of what it owes (`test_attack_chipThatStartsToTaxLater_hookAndVaultStaySolvent`,
`test_fullRound_chipStartsToTaxMidRound_cashConservation`).

## 6. Fees, rounding, solvency

- Buy: `amount = max(ceil(math.amount / scale), ceil(shares * minPriceWad))`, at least one chip unit;
  `fee = ceil(amount * f) + ceil(shares * vegaFee * vega)`. Sell: `amount = floor(...)`, same fee rounded
  up and capped at `amount`. `f(ts)` rises linearly (rounded up) over the last `feeRamp` seconds.
- Fees stay in the round's `held`. `protocolFees += floor(fee * protocolFeeBps / 1e4)`; that part moves to
  `protocolFeesAccrued[chip]` at finalize and is sent by the permissionless `collectProtocolFees`.
- Solvency after every fill: `maxPayout(40 bands) + protocolFees <= held` (section 16). A sell that would
  pay more than the round holds is rejected with the same reason. Rounds are isolated: a round can never
  spend another round's chips, even in the same chip.
- **Loss limit.** With `cushion = held - protocolFees - maxPayout`, a buy must leave
  `cushion >= capital * (1 - lossLimitBps / 1e4)`; otherwise it is rejected with `LossLimit`, a refundable
  rejection like `Solvency`. The parameter is frozen per round (default 3000, bounds 1000 to 10000).
  - *Why buys only.* A sell that had to respect the floor could trap holders in a round the house is
    losing. The design chooses the exit over the hard cap. The cost is stated in SPEC 7.5: with positions
    on two sides, sells can take the cushion under the floor (measured: 44% of the capital with the limit
    at 50%). With one product they cannot: a sell pays at most one chip per ticket and takes one chip of
    payout per ticket off the worst band.
  - *Why a floor of 1000.* At alpha 0.2 with no product cap, one-sided buying at one price puts at most
    about 4% of the capital at risk on the pair, 12% on a floor and 16% on a floor with the half of the
    pair over it (SPEC 7.5). So a limit of 10% already refuses ordinary buying. Anything tighter would stop normal play.
  - *Why 30%.* In simulation the loss limit is the one protection that costs nothing in ordinary flow:
    at 30% the mean and the refusals are unchanged in ordinary conditions, the worst simulated day goes
    from -42% to -32% of the capital, and the whipsaw gang, which takes exactly the limit on any menu,
    takes 30% instead of 50%.
  - *Why it is cheap.* The check reuses `maxPayout` and the protocol fees the solvency check computes
    anyway; one comparison more. It lives in `PitMath.postFillCheck`, which the lens calls with the fill
    applied, so `lens.quote` returns the same verdict the hook will reach (`rejection`).
  - *Rounding.* Compared cross-multiplied (`cushion * 1e4 < capital * (1e4 - lossLimitBps)`), so the floor
    is never rounded down in the trader's favour.
- `minCapital` is in whole chips (`minCapital * 10^decimals`).

## 7. Settlement, void

- `settleRound` can run again on a `Settled` round only when the recorded close changed (a trustless
  print replaced a keeper print). `finalizeRound` requires the settled price to equal the recorded close,
  so a replaced close cannot be finalized without re-settling.
- The guardian cannot void (section 17). Its dispute window ends at the instant finalization opens.
- **Void refunds.** `premium[i]` is what buyers paid for the outstanding supply of product
  `i`. A sell removes the larger of the sold shares' average cost (rounded up) and the chips the sell is
  paid. The second term matters: with average cost alone, buying a large lot at a pushed-up price and
  selling it straight back would leave part of the expensive lot's cost in the basis of the tickets still
  held. On a void **the house comes first**: it gets back the capital it brought, as far as the round still
  holds it. The outstanding tickets share `held - capital` (zero when the round holds less than the
  capital), pro rata to cost basis and never more than their cost basis; each ticket then redeems for
  `premium[i] / supply[i]`. Protocol fees of a void round are cancelled. Refunding every holder's full
  cost out of whatever the round held would let a position that went up be sold at a profit while a
  position that went down is refunded in full, with the house paying for both. With this rule traders as a
  group get back exactly what they as a group still have in the round, and a void costs the house nothing.
- Refunds are per ticket, not per buyer: tickets of one id are fungible and there is no per-buyer ledger,
  so a late cheap buyer and an early expensive buyer of the same product get the same void refund per
  ticket.
- A losing ticket cannot be redeemed (it reverts); a winning one pays exactly one chip, with no deadline.
- `redeem(id, holder, amount)` is callable by the holder, or by the router for its own caller
  (`router.redeem`, `router.redeemFor`).

## 8. Opening a round

- The book allows `openRound(ticker, chip, day)` only for the next round: the newest recorded close is 1
  to 6 calendar days before `day`, and every day in between that would have had a round (a weekday on the
  stock clock, any day on the every-day clock) is `skip`ped or missed (no close 12 hours after its
  instant). This stops anyone from locking a house into a round further ahead. Holidays and early-close
  days must be marked with `skip`, a day ahead. Six days: a Wednesday close before Thanksgiving and its
  early-close Friday is five days before Monday. The round is priced on every trading day it spans
  (section 17).
- A round is opened as soon as it can be (section 15): the keeper opens it right after it finalized the
  round before, and it trades from then on. A quiet house needs no keeper for it: `router.openAndCommit`
  opens the round when nobody has yet (status `None`) and commits the first player's trade in the same
  transaction, at that player's gas.
- **Open depths per house.** The part of a round's opening depths that depends on sigma alone
  (`math.openLnInv`) is stored per house (`_lnInv[house]`, 10 slots) and written over at each open, not 40
  new slots a round. A fill sends it with the round's capital and alpha, and the engine derives the depths
  itself (`math.fillPacked`).
  Only the latest round of a house trades, and settling, finalizing, voiding and redeeming never read the
  depths; so an older round's depths are not kept (`getCurve` returns zero depths for it). An open costs
  about 0.84M gas (about 1.06M for the first round of a house) and does not grow with the menu.
- **Band state per house.** The pricing state lives in one set of slots per house (`_bands[house]`: a tag
  with the round it belongs to, the last root and the 20 words of `v`), not in new slots each round. The
  first fill of a round finds another round's tag, starts from the zero state (a round's state before its
  first fill) and writes over used slots: about 5k gas a slot, not 22k for a new one, so the first fill of
  a house's next round costs about 0.36M gas less. An older round's `v` is the zero state once the next
  round traded (`getCurve`); nothing reads it then (settling, finalizing, voiding and redeeming do not).
- **Packed round state.** A round's state (`RoundLogic.StoredState`) is three slots: status, settlement
  flags, the depth scale `g` and the learned sigma in the first; the chips held and the protocol's fees in
  the second; the payout owed and the settled price in the third. A fill reads and writes the first two
  once each (the learned sigma no longer has a mapping of its own), and a settle writes one new slot, not
  two. `getState` returns the same `RoundState` as before.
- **Packed band state.** A round keeps its 40 band states `v` in 20 words, two signed 128-bit numbers a
  word (band 2k low, band 2k+1 high). A fill reads and writes 20 slots, not 40, and sends the 20 words to
  the engine and gets 20 back (`math.fillPacked`), not 40 each way plus 40 depths. The packing is exact:
  `ILadderMath` rejects any |v_j| above 1e36 on input and output, and 1e36 < 2^127. `getCurve` returns
  them unpacked.
- **Warm solve.** A round also keeps the root lambda its last fill returned (one slot), and the next fill
  starts its solves there (`math.fillPacked`, `math.fillFrom`). From a cold start a solve takes about 6 Newton steps of
  about 32k gas each; from the last root it takes 2 to 3. A fill saves about 85k to 115k gas; the first
  fill of a round pays about 25k more to write the slot. The first fill starts at 0: before it the round
  has the zero state, and the zero state's root is exactly 0 (the prior sums to 1e18), so that solve takes
  one step, not a cold start. `seedOf` gives the lens the same start, so its quotes match the hook's fills.
- A skipped earnings day that has a real close should have that close recorded before the next round
  opens, otherwise S0 is the close before it and the round's after-hours window is the evening before the
  skipped day (section 15, "Skipped days").
- An opened round cannot be cancelled by anyone.
- Product index `i` is the position in the round's menu (section 16); the ticket id is `roundId | i`. A
  product's price range is `S0 * exp(edge)` at the two edges of its run (`PitMath.bounds`, returned by the
  lens).

## 9. Closes and variance (PitBook)

- EWMA with weight 0.94, clamped to `[0.005^2, 0.15^2]`. The observation is the squared log return per
  trading day spanned, capped at 16 variances, and there is none across a change of the stock token's
  multiplier (section 17).
- **Who may record, and what moves the variance.** Anyone may record a close until three days after its
  instant, and never for a day before the newest recorded close; the owner is exempt (seeding, gaps). A
  close first recorded more than 12 hours after its instant is late and settles nothing (section 17,
  "A missed close is final"); it is still the next round's start price and steps the variance. The
  variance moves only on a real step: the recorded day is a day a round after the newest close could have
  (the rule `openTerms` applies, missed days included) and the close is inside its three day window. Every
  other close is stored without a step. A trustless replacement of the newest close redoes its step from
  the stored pre-step variance, and only if there was one. Without these rules a step on any newer day,
  whatever the gap, from anyone, at any age, would let a chain of cherry-picked past closes walk sigma from
  2% to 0.6% or to 7.6%. (The Pyth contract on Robinhood Chain accepts a 30 day old TSLA update and
  refuses a 44 day old one with `InvalidWormholeVaa`, so past prints verify for weeks, not for ever.)
- `recordClose` accepts either oracle source on any weekday (also skipped ones) for a stock and on any day
  for an every-day asset. A keeper print needs the ticker to have an aggregator (it is always bounded).
  The print is the oracle's close print (`verifyCloseAt`, up to `closeMaxLag` late).

## 10. Fill source policy

With two oracle sources, two prints can qualify for one instant (the first Pyth print and the first keeper
print at or after `t`), so a filler could pick the better one per commit: HIGHER on the lower print and
LOWER on the higher one is a complete set for less than one chip. `registerTicker` therefore takes a
`FillSource` that is `TrustlessOnly` or `KeeperOnly`, frozen per round; a round rejects prints of the other
source (`WrongFillSource`, not a refund). There is no "either" value. Closes have the same problem, so a
ticker has one close source too: a ticker with a Pyth feed closes on Pyth only (`PitOracle` refuses a keeper
print as its close), a ticker without one on the keeper set. Before this, a keeper close could be replaced
by the Pyth print within the challenge window, so whoever the Pyth number favoured chose the close.

## 11. Oracle fees and the fill fee (the two uses of native coin)

**Oracle fee (the filler's coin).** `IPitOracle.verifyAt` is payable. `router.fill` is payable and
forwards exactly its `msg.value` to the hook inside the fill (as the value of its `execute` call), so that a
fill that ends in a refund rolls the transfer back and the router returns the ETH to the filler. The router
holds fill fees, so it forwards only the `msg.value` of this `fill`: one commit's fee can never pay the
oracle for another commit's fill. The hook sends the oracle that `msg.value` and passes back what the oracle
refunds in the same call (to the filler through the router; to the caller of `openStrike`), so it keeps no
ETH, and its `receive()` takes the oracle's refunds only. With a zero fee nothing moves.
`PitBook.recordClose` forwards `msg.value` and returns the change to the caller; the book's `receive()`
also takes the oracle's refunds only.

**Fill fee (the trader's coin).** Without it the keeper would pay for every fill and be
paid by nobody, so the cheapest attack on the game would be to make it fill: commits cost 231k gas, fills
1.18M. Every commit carries the round's `fillFee` (default 0.000025 ETH, bounds 0 to 0.01 ETH, frozen per
round like every other parameter, so the owner cannot change what a pending commit pays).

- *Who is paid.* `msg.sender` of `fill`, whenever `fill` returns: on a trade, and on every refund made
  inside `fill` (the hook's rejections, the limit among them). The limit refund is included because it
  costs the filler the same full pricing run, and leaving it out would let a trader make the keeper work for free with a limit of one unit. One
  exception: when someone other than the user paid the fee (a session relayer, `feePayerOf`), the fee goes
  back to that payer unless the payer fills the commit itself, after a trade and after a refund; otherwise
  a user (or anyone) could fill relayed commits first and take the relayer's fees. A commit records that it
  is relayed in its first slot, so a plain fill does not read `feePayerOf`. On a timeout the fee returns to whoever paid it; the caller of
  `refund` earns nothing, so nobody is paid for letting commits expire.
- *Batches.* `fillBatch(commitIds, reports)` runs each commit through the same path as `fill`, in the
  order given, and pays each commit's fee to the caller. It takes no ETH, so it forwards no oracle fee: a
  report that needs one (a Pyth update with a fee) goes through `fill`. A commit that is not ready or
  already closed is skipped (`false`) and stays pending.
- *Exact value.* `commit` reverts unless `msg.value == fillFee`. An overpayment is not kept and not
  refunded piecemeal: it is refused, so the router's balance has one meaning.
- *Paying cannot fail.* `_payFillFee` runs last in `fill` and `refund`: the commit's status and the escrow
  totals are written, the chips have moved, the events are out. It sends with a 100,000 gas allowance and
  copies no return data (`trySafeTransferETH`); on failure it adds the amount to `ethOwed[receiver]`. A
  receiver that reverts, burns its gas or returns a huge blob therefore cannot make a fill or a refund
  revert, and it cannot be skipped either: its coin waits for `claimEth(to)`, which sends to an address of
  its choice and reverts only for the claimer. A filler that reenters from its `receive` meets the lock on
  every router entry point; the commit it was paid for is already closed, so there is nothing to be paid
  twice for.
- *One mapping.* `ethOwed` also takes a refunded fee a trader contract would not accept, and the oracle
  ETH of a refunded fill that the filler would not accept. Invariant, checked in both stateful suites:
  `router.balance == sum of fillFee over pending commits + sum of ethOwed`.
- *Not built.* No allowlist of fillers (anyone may fill and is paid), no fee in chips (the filler pays gas
  in ETH), no refund of the difference between the fee and the gas actually used.
- *Caller-chosen gas.* Whoever calls `refund` could give so little gas that a contract trader's `receive`
  fails inside the allowance; the fee then waits in `ethOwed` instead of arriving directly. Nothing is
  lost and the caller gains nothing.

## 12. Reentrancy

Hook and router each have a transient-storage lock on every state-changing entry point. The router's
`execute` accepts only the router itself under that lock, and its `unlockCallback` (the ETH swap of
`commitWithEth`) only the PoolManager under that lock. Inside the hook's `fill` the external calls are to
the oracle, the math, the book and the chip.

## 13. Owner bounds and trust

The owner seeds each ticker's variance and clock weights and sets the defaults of future rounds; those are
pricing inputs, so a hostile owner could open a mispriced round and trade against the house. The book's
hard bounds limit this (`alpha <= 0.79`, `0.5% <= baseFee <= 10%`, `closeFee <= 20%`, clock weights that
sum to 100% with at least 25% in the regular session, variance within `[0.005^2, 0.15^2]`,
`refundDelay <= 120`, `challengeWindow >= 300 s`), but they do not remove it. The book therefore delays
them: new default parameters, a new ticker and a reseed of a registered ticker (variance, clock weights,
fill source) take effect 24 hours after the owner's transaction, are visible on chain meanwhile
(`pendingDefaultParams`, `pendingReseed`), and a second announcement restarts the clock. A new guardian
waits 24 hours too, and `skip` takes only days whose close is at least 24 hours away. The clock itself
(`NYWeekdays` or `EveryDay`) is chosen at registration and cannot be reseeded. `skipAfterHours`, the pause
and the fee recipient stay immediate (the first two only remove trading or opening), and like everything
else they reach a round only when it opens. The owner should still be a multisig.

**Trust rule: the oracle owner cannot stop or pick a close at short notice.** Which close settles a round is
decided by the oracle, so the oracle owner's powers that can change it wait too (`PitOracle`,
`SIGNER_DELAY`, 24 hours on mainnet, each queued in the open and cancellable):

- the signer set and the threshold (`setSigners`, `setThreshold`, `pendingSigners`);
- every change of a ticker's configuration that is set already, the fill-in of a missing Pyth feed id or
  aggregator included, and every numeric limit (`maxLag`, `maxConfBps`, `boundBps`, `maxFeedAge`,
  `closeMaxLag`) (`setTicker`, `pendingConfig`, `cancelTickerChange`). Only a ticker's first configuration
  is immediate: nothing verifies for it before;
- switching a source off for closes (`setSourceDisabled(.., true)`): the source then refuses only closes
  whose instant is at least `SIGNER_DELAY` after the switch (`closesOffFrom`). The instant counts, not
  the time of recording, so a switch is always made before the results it reaches are known. A round that
  opens less than `SIGNER_DELAY` before its close keeps its close whenever it is recorded. A Monday round,
  open from Friday, can lose its close to a switch made over the weekend (see below);
- switching a source back on for closes: if the source had not yet refused any close instant, closes come
  back at once. Otherwise the instants from `closesOffFrom` to `SIGNER_DELAY` after the switch back on stay
  refused (`closeGap`). Without this the owner could switch both sources off before a Monday close, watch
  the result, and switch them back on only when the house wins: void if the house loses, settle if it wins.
  A source keeps up to eight gaps. A new gap merges with a live gap only when the two overlap or touch;
  otherwise it takes its own slot. Merging gaps that do not touch would cover the time between them, when
  the source was on, and a close made then and left unrecorded would be refused: the owner could switch off
  and on again to void that round once its result is known. Kept apart, a second off and on never frees a
  close an earlier gap refused, never refuses one no gap covers, and never blocks the switch. A gap is
  dropped three days after its end (`CLOSE_RECORD_WINDOW`): only the owner's late path can still record a
  close inside it, and a close first recorded that late settles no round. On a testnet (no delay) there is
  no gap, so the owner can fill in older closes.

Immediate are only: the fills of a source switched back on, and the emergency brake, which stops fills of a
source at once (`sourceDisabled`, `verifyAt`; `setFillsPaused` is the brake alone, with no change for
closes) and never touches `verifyCloseAt`. A stopped fill is not final: the
commit refunds when its window ends. So the owner can halt trading in an open round but
cannot void it or pick its close. The views (`config`, `boundBps`, `multiplier`, `supported`,
`sourceDisabled`) return what is in force; `pendingConfig` and `closesOffFrom` show what waits. On a testnet
(`SIGNER_DELAY` zero) everything applies at once, a switch-off of closes included.

What is left: a round open longer than `SIGNER_DELAY` (Friday to Monday) can still lose its close to a
switch-off made after it opened, announced at least 24 hours before the close and before its result is
known. A signer or configuration change applies to every verification from the moment it is in force, so
it reaches the close of a round that was open when it was announced only when that close is recorded more
than 24 hours after the announcement (the keeper records at the bell). And a ticker without a Pyth feed has its close only from the keeper quorum: a quorum that withholds
the close voids the day's rounds. At launch every mainnet ticker is `KeeperOnly` with no Pyth feed
(`DeployMainnet.PYTH_AT_LAUNCH`): its close comes only from the keeper quorum, and a quorum that withholds
it voids the day's rounds. A Pyth feed added later (`PitOracle.setTicker`, 24 hours) lets anyone record
the close from Hermes.

`minCapital` is tied to the engine: `alpha * minCapital >= 1e15` (alpha in WAD, `minCapital` in whole
chips) guarantees that `LadderMath.openDepths` accepts every round that passes the hook's `minCapital`
check, and `minCapital * maxFillBps / 1e4 >= minTrade` that the smallest round can still trade. At the
default alpha 0.2 the default `minCapital` of 1000 gives `alpha * minCapital` of 2e20, far inside the
bound; the default menu opens and trades every product on exactly 1000 chips
(`test/integration/MinCapital.t.sol`).

## 14. What the hook does not protect against

- A wrong pricing engine. The solvency check guarantees that outstanding winning tickets are always
  covered and that one round cannot touch another, but an engine that underprices lets traders take the
  round's own capital. The loss limit (section 6) caps that at 30% of the capital at its default when one
  product is given away (`FallpitBrokenMathTest`); an engine that gives away tickets on two sides and buys
  them back dear can still be walked down to the solvency bound, because sells are exempt from the limit
  (`FallpitBrokenMathTest`, SPEC 7.5).
- Keeper downtime longer than `refundDelay` (commits refund; see section 4).
- Trading in the extended hours on an engine that was only simulated on the regular session (section 15).

## 15. The round clock

Rounds run from one close to the next and trade through the extended hours. SPEC 7.2 has the
rules; this section has the reasons.

- **Two clocks, chosen at registration.** `NYWeekdays` for stocks, `EveryDay` for assets that trade
  around the clock. The clock decides which days have a close and a round, what "the next round" is, and
  which seconds trade. It is not reseedable: the ticker's closes and its variance steps are counted on it.
- **Where it lives.** The hook has little room under the size limit. The clock is a library (`PitClock`)
  compiled into the book, and the hook asks `book.clockAt(clock, ts)`: a pure function of the round's own
  frozen clock, so the book still has no power over an open round (it cannot answer differently for the
  same arguments, and it has no upgrade path). The lens compiles the same library, so `lens.quote` and
  `lens.clockAt` agree with the hook by construction.
- **One slot.** `RoundClock` (kind, after-hours flag, windows mask, two day numbers, four 16-bit weights)
  is 152 bits. The instants are recomputed from the two day numbers on every call (a few thousand gas
  inside a 1.18M gas fill) rather than stored: fewer bytes in the hook, and one place where daylight saving
  is decided.
- **rho, one number.** It says how much of the round's variance is ahead. `sigma` is the EWMA of
  close-to-close returns, so it covers exactly the round's horizon and nothing has to be scaled:
  `sd = sigma * sqrt(rho)`, and the opening prior (`rho = 1`) is the one the depths are built on
  (`openDepths` uses `prior(sigma, 0, sigma)`).
- **Weights, not a model.** After-hours 6%, gap 14%, pre-market 10%, regular 70% are starting values the
  owner can change per ticker with a day's notice. They are not fitted to data. The regular session keeps
  at least 25% (less would make the prior a near point mass at 09:30).
- **The gap is a jump for the book.** rho is continuous in wall-clock time, also through the night and
  the weekend. Nothing fills there, so the first pre-market fill reprices with the whole gap gone: `sd`
  and the depth scale `g` both step down at once (the rescale in `LadderMath.fill` moves no price).
- **A windows mask instead of fixed windows.** Which of a stock round's four segments trade is a
  per-ticker mask (1 after-hours, 2 overnight, 4 pre-market, 8 regular), frozen in the round; the default
  13 trades the after-hours, the pre-market and the regular session. The Pyth feeds of TSLA and QQQ publish
  24/5, nights included, so the nights can be worth trading for a `TrustlessOnly` stock. With the mask the
  owner switches them on per ticker with the usual 24 hours' notice (a reseed with `windows = 15`) and no
  new deployment. Nights are weekday nights: 20:00 to 04:00 into a weekday's morning. Friday 20:00 to
  Sunday 20:00 never trades and neither does the daytime of a skipped day in the gap. The clock does not
  change: rho already runs through the gap in wall-clock time, so a night fill sees the gap's weight
  partly gone instead of all at once at 04:00. The daily after-hours flag stops its evening's after-hours
  only; a round whose nights trade starts at 20:00 that evening. Nothing about night trading has been
  simulated either.
- **Edges.** The after-hours are `[16:00:00, 20:00:00)`, the pre-market and the regular session together
  `[04:00:00, cutoff]`. 20:00:00 is excluded so that "no trading from 20:00" is true of the second 20:00:00
  itself; the cutoff is included.
- **Commits are checked at their fill instant.** `commitContext` returns `tradable` for
  `block.timestamp + fillDelay`; the router refuses the commit otherwise. The hook checks the print's own
  second again, because the print for `t` may be up to `maxLag` later than `t`: a commit made in the last
  seconds of a window can be priced by a print made after it, and is then refunded (`Window`) with the
  fill fee going to the filler like any other final rejection.
- **`skipAfterHours` is read at the open.** It is immediate for the owner (no 24 hours) but frozen in the
  round like every other input. An emergency switch that reached open rounds would be a new owner power
  over open rounds (it could also be used to stop exits for an evening), which the design does not have.
  So the flag must be set before the round opens, which with the keeper is seconds to fifteen minutes
  after the close of the day before. Earnings dates are known days ahead.
- **Skipped days.** A stock round starts from the newest recorded close and its after-hours window is the
  evening of that close. For a holiday that is what one wants (Wednesday evening before Thanksgiving, then
  Friday 04:00). For a day skipped for earnings it is not quite: if Tuesday is skipped because of Monday
  night's earnings and Tuesday's close is not on the books yet, Wednesday's round can be opened by anyone
  on Monday at 16:01 and trades Monday's after-hours, into the release. It is priced on two days (sigma
  times the square root of two, section 17), not one; the release still lands on an open book. Two things
  prevent that and both are operations, not code: set `skipAfterHours` for the day after a skipped
  earnings day as well, and record the skipped day's close (the keeper tries every weekday's close except
  its calendar's holidays and early closes, and waits for it before it opens the round after a skipped
  weekday).
- **Every-day rounds.** On the every-day clock a round normally starts from the day before. A skipped day,
  or a close missed for 12 hours, is spanned like a skipped weekday on the stock clock: the round runs from
  the newest close, its rho is one straight line over the whole span, and its sigma covers every day of it
  (section 17).
- **Challenge window 900 s (300 to 3600).** With a keeper-signed close the house's next round opens only
  after the window, and its after-hours trading starts then: an hour would cost a quarter of the
  after-hours. A trustless close still finalizes at once.
- **Not validated.** The engine's simulations traded the regular session only. What the
  tests add is that the contracts and the Python reference agree to rounding on a round traded in all
  three windows, and that the worst case of one-sided buying at one price is about the same in the
  after-hours as in the session (SPEC 7.5). Nothing measures the engine against real extended-hours
  prices: wide spreads and stale last trades in the quote sources, a release that moves the stock several
  sigma in a minute while the book is open, the size of the overnight jump against the 14% it is given,
  and the oracle sources' own behaviour outside 09:30 to 16:00 (SPEC section 8).

## 16. The floor menu

A round has a menu of products, each a claim on a contiguous run of bands, a "pick the floor"
menu. SPEC 7.2 and 7.5 have the rules; this section has the reasons.

- **A product is a run of bands, nothing more.** `LadderMath.fill` prices any contiguous set `[lo, hi]`;
  HIGHER and LOWER at the previous close are two special cases. So the engine needs nothing per product:
  the winners, the worst payout and the lens work on runs.
- **The menu is one word.** Twelve products of two bytes each and a count fit in 25 bytes. One storage
  slot in the round's config, one `SLOAD` per fill, and no array handling in the hook. It rides in
  `Params` with the other defaults, so it has the same owner bounds, the same 24 hours and the same
  freeze per round without a second pending-change mechanism in the book. `PitBook.packMenu` and
  `unpackMenu` are for the owner and for apps.
- **One default for all tickers.** Edges are in quarter sigmas of the ticker's own day, so one menu
  means the same thing for a 1.2% stock and a 5% stock. A menu per ticker would be a second reseed path.
- **No shape is special in the hook.** Runs may overlap, repeat and leave bands uncovered; the hook
  never asks whether the menu partitions the ladder. The default does (eight floors) and adds the pair on
  top, so every band is covered by exactly one floor and one half. A menu with a gap is a menu where
  some closes pay nobody: allowed, and tested, because refusing it would be a rule with no safety
  reason behind it.
- **Twelve at most.** A product is a ticket id, not a contract, so the gas of an open does not grow with
  the menu. The limit is the fixed arrays in the round (`supply`, `premium`) and the 16-bit mask of
  winners.
- **The worst band.** With arbitrary runs the payout is a function of the band: the sum of the supplies of
  the products over it. `PitMath.maxPayout` takes the largest of the 40 with a difference array (add the
  supply at `lo`, take it off after `hi`, one running sum): 2 writes per product and 40 additions, a few
  thousand gas in a 1.18M gas fill. The stateful suites recount it band by band after every call.
- **Solvency and the loss limit are about the worst band.** Both are statements about the cushion in the
  worst band, and that is one number. A product over the same bands as another deepens the same worst band
  (a floor and HIGHER); a product over other bands does not (a floor and LOWER on the other side).
- **Why a product cap, and why only on floors; and why it is off by default.** A far floor is a cheap
  ticket with a large payout: one buyer could put a tenth, a half, all of the capital at risk in one
  band for a few percent of premium, with the loss limit as the only brake. `floorCapBps` bounds the
  house's exposure to any one floor directly. In simulation a cap at 10% refused 48% of the retail dollars at 0.5x of capital per
  day and 67% at 2x, with the house's result falling by half and more, while the loss limit at 30%
  protects the tail just as well and never refuses balanced flow: a supply cap cannot tell retail from
  attackers, the loss limit can. The default is therefore 10000 (no cap; a floor may hold the whole
  capital in tickets, and the engine bounds its exposure near alpha times the capital like the pair's).
  The code, the bound and the tests are there for an owner who wants a cap, not below 5000. The pair is
  exempt because it does not need it: a half of the ladder costs about half a chip and goes to one chip
  as it is bought, so the engine itself bounds the exposure (about 4% of the capital at alpha 0.2, SPEC
  7.5), and capping the product beginners use most would cap the game. "Narrower than half the ladder" is
  the line: 19 bands and fewer are capped, 20 and more are not. The cap is checked before the oracle is
  asked (it does not depend on the price), so a keeper spends no pricing run on a commit that can never
  fill, and the refund works with any report.
- **The cap is per product, not per band.** Floors that overlap each bring their own cap to the bands
  they share, and the pair brings none: what bounds a band is the loss limit. On the default menu every
  band has one floor, so one cap.
- **What the cap costs, when a round has one.** It is a product's, not a trader's, so whoever fills it
  locks the floor for everybody else until they sell. Cornering a far floor is cheap (0.7% of the
  capital for the far floor at the previous close with a cap of a tenth). It blocks one product, costs
  the cornerer real exposure and a losing round trip, and the lens says `ProductCap` before a user
  commits; a user who commits anyway loses the fill fee to the filler, as with every final rejection.
  With no cap there is nothing to corner.
- **Why a minimum price.** The prior is floored at 1e-4 per band, so a floor far from the oracle price
  costs a few thousandths of a chip a ticket: a large position for dust. With `minPriceWad` (0.02 by
  default) every ticket bought costs at least two hundredths of a chip before fees, which also caps what
  a ticket can pay at 50 times its price. It is a floor under the charge, not under the price: the
  engine's state moves as if the engine's own price had been paid, the difference is extra premium for
  the round, and a sell is paid the engine's price. So a buyer at the minimum who sells back loses the
  difference, and nothing in the pricing state is distorted. Buys only: lifting sells to the minimum
  would pay holders more than the engine values their tickets at.
- **Complete sets.** The property that makes a menu safe is that covering every band once can never cost
  less than one chip. It holds for any partition into runs because the cost function is translation
  invariant and the buys telescope; the minimum price and every rounding step only add to the cost. The
  tests measure it on the four ways the default menu offers (SPEC 7.5), before fees, at one print. It is
  a statement about one print: two halves bought at two different prints are a bet on the path.
- **Price ranges are a view.** A product's prices are not stored: `PitMath.bounds(S0, sigma, lo, hi)`
  computes `low` and `high` from the round's frozen `S0` and `sigma`, with the same one-line edge formula
  as the engine (`PitMath.edge`, checked against `LadderMath.edge` by a fuzz test), and the lens returns
  them with each product. The hook does not carry them, for its size.
- **Names.** The hook gives every ticket one name ("Fallpit ticket", `PITTIX`); the id says which round
  and product. The app names a product from its run and its price range: a floor in the middle by both
  prices, the pair by `HIGHER` and `LOWER` and the previous close.
- **Unknown products.** For an index the menu does not have, `commitContext` returns a zero id and the
  router reverts with `UnknownProduct`; the lens's `quote` reverts with its own `UnknownProduct`, and the
  hook's `fill` and `redeem` with `UnknownToken`.
- **One call per market.** `FallpitLens.market(roundId, price, ts)` returns the round's header (status,
  clock, fee rate, cushion and limit, caps, minimum price, fill fee) and every product with its run, its
  price range, its ticket id, supply, cap usage, the engine's price, the price a buy is charged at (the
  minimum when that is higher), the payout multiple and `dead`. One `math.prices` call prices the whole
  menu: a product's price is the sum of its bands'. `payouts(roundId)` returns what the round owes per
  band.
- **Dead products.** The minimum price is income from the uninformed: a long shot the model prices at a tenth of a cent is charged two cents, and a lens that
  advertises "50x" on it sells a lottery ticket at twenty times its fair price. `Product.dead` is true
  when the engine's price is under the minimum, so an app greys the product out; then "charged at least
  0.02" behaves like "no sale under 0.01", which protects the tail the same and is honest to players. The hook does not refuse such buys: the flag is advice to the app, the rule stays the charge.
- **The multiple at size.** `Product.multiple` is the next ticket's. A buy moves the price, and at
  alpha 0.2 a 100 coin buy on a tail floor pays about 13x where the first ticket pays 28x. `buyCosts(roundId, product, price, ts)` prices one ticket, ten and the per-fill cap all in
  (three `math.fill` calls) and returns the multiple of each, so the app can show the
  multiple for the size in the user's hand. It is per product, not per menu: thirty pricing calls in
  one `eth_call` would run into RPC gas caps.
- **Validated by simulation, not by play.** A simulation of 2.2 million days set the defaults: the eight floors as they are, alpha 0.2, no product
  cap, loss limit 30%, minimum price 0.02, vega fee 0.10. With them the floor menu gives up at most
  0.16 points of capital a day against HIGHER/LOWER when nobody but an informed trader plays, and is
  ahead by 1.4 to 5 points a day with any real retail flow. What stays open: the leak to a vol-informed
  trader on days when the realised vol is far from the EWMA (house-side
  intraday vol learning, `setSigmaEff` with the vol-mixture prior, addresses it; section 18 has its
  bounds), whether players pay the vega fee's price, and the elasticity of demand. The contracts take any
  parameters inside the book's bounds without a new deployment.

### 16.1 Live strikes

SPEC 7.3.2 has the rules. The pair splits at the previous close, so its odds pin as the close comes near:
on testnet the pair was past 95/5 in the last 15 minutes on every day measured and from 15:00 on two days
of five, as simulation predicted (55% of rounds at 15:00). A strike is a second pair at the price.

- **On the existing grid.** A strike splits at an inner edge of the round's 40 bands, so it is two more
  runs in the menu and nothing else: the engine prices runs, and the winners, the worst band, void and
  redeem work per product. A finer grid would change the band count and the math for 0.04 to 0.07 of odds.
- **The nearest edge, not the caller's choice.** Anyone may open a strike, so the rule must leave nothing
  to choose: the edge is set by a verified print of a recent instant. Any edge would be honestly priced;
  the rule is there so nobody can use up the room on edges far from the price.
- **Half of the variance.** Before that the pair is still near even odds (at 12:00 the pair was past
  90/10 on one testnet day of five), so a strike would only use room. At `rho <= 0.5` a stock round is in
  its afternoon session and an ETH round in its last 12 hours.
- **Two edges apart.** A strike one edge from the pair or from another strike is a quarter sigma from it:
  nearly the same bet, and room spent. Two edges keeps each strike a different bet.
- **Every pair pinned, on chain.** With only the variance and spacing rules, anyone could spend both
  slots at `rho = 0.5` while the pair is still near 76/24, and a later run of the price would have no live
  pair. So the print must be at least 0.84 remaining standard deviations (80/20) from edge 19 and from
  every open strike's edge. It is measured on the learned sigma, as the engine prices, and needs no
  engine call: the normal law at the remaining sd is the pair's odds up to the band state.
- **A recent instant.** The print of any instant inside the refund window (up to 120 seconds) would let a
  caller choose the most extreme print of that window. The instant must be at most 30 seconds old.
- **The caller pays the oracle.** Fills spend the hook's balance on the oracle fee (the router sends the
  fill's value first). A strike sends only its own `msg.value`, so it cannot spend ETH the hook holds.
- **At most 15 products.** The menu word has room for 15 runs and the winners mask for 16. The default
  menu (10) takes two strikes, which is what the day needs: one when the pair pins, one more if the
  price runs on. The book keeps its own menus at 12, so every round has room for at least one.
- **Cost to the house.** In simulation: about -0.07% of the capital a day in the informed-trader cells (more
  products near even odds give an informed trader more to choose from); the pooled worst case and the loss
  limit bound the strikes as they bound every other product.

## 17. Multi-day rounds, disputes, fill order, outages

- **A round is priced on every day it spans.** `openTerms` counts `k`, the days without a close between
  the close a round starts from and its day (skipped or missed weekdays on the stock clock, any such day on
  the every-day clock; weekends are inside the close-to-close EWMA and do not count), and returns
  `sigma * sqrt(1 + k)`. On the stock clock it also divides the after-hours, pre-market and regular weights
  by `1 + k` and gives the gap the rest: those three windows keep one day's share of variance each, and
  the extra days sit in the gap, where they are in time. Without that, rho at the pre-market would
  overstate the variance left by the factor `1 + k`. The bands are in quarter sigmas of the round, so a
  four-day round's tail floor starts twice as far out and costs what a one-day tail costs: the edge is
  where four days put it. The close at the end steps the EWMA with the squared return divided by `1 + k`.
  `setSkip` takes a day only while its close is at least 24 hours away (so the owner cannot skip and open
  in one transaction); `skipAfterHours` stays immediate because it only removes trading.
- **The guardian disputes, it does not void.** A guardian that could void a settled round would cost the
  house the profit of the bets it voided, so a guardian with a partner could sell free options. `voidRound`
  voids only an open round with no close a day after its close. The guardian's one power is
  `PitBook.dispute(roundId)` inside the challenge window of a keeper-closed round: every round on that
  close then finalizes only one hour after the close (`DISPUTE_WINDOW`), and until then anyone may replace
  the close: with a trustless print (always, final), or once with another keeper print for the same
  instant that differs by more than the oracle's bound. The replacement rule is what keeps the dispute from
  being gamed: a keeper print can only correct a gross error (a band is a quarter sigma, 50 bps at 2%, so
  a small replacement could flip a band on a whim), and one replacement means nobody can trade
  replacements back and forth and win by speaking last. The guardian alone produces no print, so a dispute
  changes nothing unless a correct print exists; it costs the ticker's houses about 45 minutes of the next
  round's after-hours (finalization moves from about 16:15 to 17:00; a 24 hour window would move it past
  the next cutoff and cost a trading day), which is why the guardian is trusted for liveness and nothing
  else. An hour is enough for its purpose: Pyth publishes the 16:00 update within seconds, and the keeper
  compares the close with its other sources inside the 15 minute challenge window. A dispute after the
  hour reverts (`DisputeNotAllowed`) instead of recording a window already over, so a close recorded late
  (after about 16:45) cannot be held open. `dispute` lives in the book because the close is the book's and
  is shared by every house of the ticker: finalize reads `closeState` (price, trustless, dispute end), so
  all rounds on a disputed close wait, not only the one the guardian named. The book reads the round
  through the hook, wired once by its deployer (`setHook`, checked against `hook.book()`). `setGuardian`
  waits 24 hours (`pendingGuardian`).
- **Fill order.** The fills of a round go in commit order. One print prices every instant it covers (after
  a gap in the prints, many instants), so an order per instant is not enough: a commit made one second
  after the victim's, at the same print, could be filled first and sandwich it. The router records with
  each commit `prev`, the round's commit before it, whenever the fill windows of the two overlap
  (`_lastCommit[roundId]` holds the newest one and its instant; the instant never goes back within a round,
  so one slot per round is enough), and `fill` reverts while `prev` is pending and its window is still
  open. Fill instants only grow within a round and all its commits have one `refundDelay`, so an earlier
  commit's window ends first: a stuck commit holds the next one only until then (the next one keeps at
  least the seconds between the two instants to fill in), and after that it waits for `refund` and holds
  nobody. Cost: one slot written per commit, one cold read per fill that has a `prev`. The residual is a
  buy committed ahead of the victim's: it needs a guess on an FCFS sequencer, not a backrun.
- **New tickers wait.** A registration goes through the reseed slot with an eta 24 hours ahead; until then
  `getTicker` shows nothing in force and `pendingReseed` shows the registration. The vault's gate is the
  book (`supported`: registration in force and an oracle source), so no house can be created and funded
  before LPs can see the ticker's terms.
- **The close is robust to a short outage.** The oracle verifies a close with `closeMaxLag` (300 s by
  default, 60 to 900) instead of the fill's 30 s. A close that never comes is "missed" 12 hours after its
  instant (`PitClock.MISSED_CLOSE`): the book then lets the next round open from the newest close
  (spanning the missed day), and `openRound` voids the house's open round of the missed day in the same
  call, exactly as the 24 hour void would (one internal `_void`, shared by `voidRound` and `openRound`).
  The 24 hour void stays for everyone else. A missed close costs its own round, not the next day's too; the
  missed day's variance is in the next round's sigma.
- **A missed close is final.** From 12 hours after its instant, a close that is not recorded can void the
  day's rounds (above). A close first recorded after that point is `late` (`PitBook.Close.late`): it is
  stored, it is the next round's start price and it steps the variance, but `closeState` shows no close for
  it, so it never settles a round and never stops a void. Without this, once the result was public on
  Hermes, whoever acted first after 04:00 chose per house: the losing side voided (cost basis back), the
  winning side recorded the close and settled. So a close settles only when it was recorded in time, and
  for a ticker with a Pyth feed, anyone can do that from the public Pyth update until 04:00. `closeOf` still returns a late close, for the
  start price.
- **Corporate actions.** The book stores the stock token's multiplier (`oracle.multiplier`) with every
  close and skips the EWMA step when it differs from the close before, so a split does not send sigma to
  the clamp. Independently, every observation is capped at `(4 sigma)^2`, so a jump the multiplier does
  not explain moves the variance by at most a factor of about 1.9 in one step. A round whose close and
  starting close have different multipliers does not settle (`CorporateAction`): it voids, because its
  bands were cut on the price before the split. Without this a forgotten `skip` on a split day paid the
  low floors and LOWER in full. A close keeps the multiplier of its first write: a replacement moves the
  price, never this test, so a settled round can never later look like it spans an action (if one does,
  `voidRound` and the house's next open void it instead of leaving it locked). The multiplier is read when
  the close is first recorded, so it must not depend on when that is: a stock token added to a ticker later
  takes effect only from 04:00 to 15:30 New York (`PitOracle.clearOfCloses`), outside the hours in which a
  close is made or can still settle. A Pyth feed added later waits the same way, because it changes which
  source may record the close (a ticker with a feed closes on Pyth only). What stays: an issuer that changes `uiMultiplier` itself between 16:00
  and the recording. Issuers apply a split before the market opens, and the keeper records the close within
  minutes; the owner's `skip` for a known action day is still the first defence.
- **Discovery views.** The ticker list for apps (`tickers()` on the book) is read by `FallpitDirectory`;
  the app's other discovery views live in that second lens, not in the hook, the book or the vault.

## 18. Pricing and risk bounds

- **The risk budget is keyed by the print, not the commit.** One print prices every commit instant in
  `(prevTs, ts]`, up to 31 of them. Keyed by the instant t instead, one print after a keeper gap would fill
  one budget per instant (8x in a test). `_fill` calls `book.takeRisk(roundId, ts, risk, budget)`
  with the print's own `ts` from `verifyAt`. The hook computes `budget` from the round's frozen config,
  `capital * riskCapBps * gNew / 1e4` (`PitMath.riskBudget`), with `gNew` the depth scale at `ts`; so the
  book does not call back into the hook. One print takes one budget (`PrintGapBudget.t.sol`: 21.8k of a
  25.1k budget, 13 of 40 commits filled). The book keeps one sum per round, for its latest print: the router
  fills a round's commits in order, so its prints only go forward. If two keeper prints ever cover the same
  instant, a fill on the earlier one is charged to the later print's sum: it cannot reset the sum, and it is
  not refused for its order.
  The lens (`riskBudget`, `quote`, `maxBuy`) reads the same key with the same g. A commit for instant t is
  priced by the first print with ts >= t; for a t in the future that is a print of t itself, so the app
  passes the fill instant.
- **Bounded vol learning.** The bounds live in the book (`PitBook.stepSigmaEff`, called by `setSigmaEff`),
  which keeps the hook small. Per update: at most 10% up or down from the sigma in force, one update per 5
  minutes (`SIGMA_EFF_GAP`). Overall: 0.8x to 1.5x of the round's frozen sigma. Per round: the product of
  all rises is at most 1.5, so once the sigma has risen 1.5x in total it can only fall, and a keeper cannot
  cycle it. The book stores the state (`sigmaEffState`: sigma, time of the update, rises so far); the hook
  keeps the value for its fills. `OnlyVolKeeper` and `SigmaEffTooSoon` come from the book.
- **The data behind the limits.** A simulation with the on-chain rule (an update every 5 minutes inside
  the clamps, 1,000 days per condition, against the vol-mix prior without learning). Mean gain when the
  house's vol is mispriced, % of capital a day: unbounded learning every minute +0.35; **0.8x to 1.5x,
  10% per 5 minutes, rise budget 1.5 (the rule here) +0.31, 88% of the gain**; a 0.5x or 0.6x floor
  +0.34 (97%); a top at 1.25x +0.28 (81%). The rise budget costs nothing (0.5x floor with and without
  it: +0.337 and +0.334). The 1.5x top gives back part of the worst-day gain: worst day -27.2% against
  -7.9% unbounded (-38.9% without learning). The 0.8x floor loses most in
  the "house vol too high" world. The whipsaw day is unchanged (-1.44 against -1.43).
- **What is left.** A colluding or stolen vol keeper key can still be worth about 1.8% of capital to a
  trader once per round: buy the tails, ramp the sigma to 1.5x in 20 minutes, sell
  (`test_fastestRampIsBoundedOncePerRound`, +18.3k on 1M; with no per-update bounds and a top of 2.5x,
  +47.6k in a few minutes, repeatable all day). A slower attack gains 1.2k, less than the same round trip
  costs with no sigma change (3.8k). A down ramp to 0.8x on the centre floors loses (-5.0k). Limits cannot
  close this: a tail's price moves about five times the sigma step, and the fees are a few percent. So the
  vol keeper is a trusted role; it is unset (zero) by default.
- **Mainnet delays.** The `PitBook` and `PitOracle` constructors revert with `DelayTooShort` when
  `OWNER_DELAY` or `SIGNER_DELAY` is under 24 hours on chain 4663, 1, 42161 or 8453. The testnet (46630)
  and anvil (31337) take any value.
- **Sells keep their full weight in the budget.** A sell counts its whole payout as risk. Nothing supports
  a lower weight, and a lower weight would let a bad print pay out
  more through sells. A trader who pays the fees can still fill the budget of one print with sells and push
  honest commits of that print to a `Cap` refund; the refund is in full and the next print has a fresh
  budget.
- **`maxBuy` matches the hook.** It applies every check of a buy: the per-fill ceiling, the product cap,
  the trading window, the print's risk budget, solvency and the loss limit (`_takes`, in the hook's order).
  An app's "max now" is then a size the hook takes if no other fill lands first.
