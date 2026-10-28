# Vault, ChipGuard and CommunityTreasury: design

Covers `src/PitVault.sol`, `src/ChipGuard.sol` and `src/CommunityTreasury.sol`. `SPEC.md` sections 2, 5
and 6 state the rules; this document gives the reasons, the details the SPEC leaves to the code, and what
was measured on chain.

## 1. PitVault

### 1.1 Books of one house

| Field | Meaning | Where the chips are |
|---|---|---|
| `lpAssets` | capital owned by the shares | vault when unlocked, round when locked |
| `endowment` | capital that owns no shares (donations) | vault when unlocked, round when locked |
| `pendingDeposits` | deposits queued during a round | vault |
| `pendingDonations` | donations made during a round | vault |
| `claimableTotal` | processed withdrawals not yet claimed | vault |
| `pendingShares` | shares queued for withdrawal (held by the vault's own ledger entry) | n/a |

`accounted[chip]` is the sum over all houses of that chip of what is in the vault. The invariant test
checks `sum heldFor(house) == accounted[chip] <= balanceOf(vault)` after every call.

Share price is `(lpAssets + 1) / (totalShares + 1e6)`: virtual assets 1, virtual shares 1e6, so a fresh
house mints 1e6 shares per chip unit. The endowment is not in the price, so a donation can never be used to
inflate it, and neither can chips sent straight to the vault (1.5). The first-depositor attack has nothing
to push on.

### 1.2 Queues

- Unlocked house: `deposit` mints at once, `requestWithdraw` burns and **pays at once** (no separate
  `claim`).
- Locked house: both are queued. Queued shares move to the vault's own ledger entry and keep bearing the
  round's result. Queued chips stay in the vault.
- The queue is processed at one price, the price after the round's result, withdrawals and deposits both
  using the price from before either. It runs in `pullRoundCapital`, and also on the first LP call after
  the round returned (`deposit`, `requestWithdraw`, `claim`, `settle`, or the permissionless
  `processQueues`). The price is the same in every case because nothing but a round result moves it.
  **Reason:** with processing only in `pullRoundCapital`, queued withdrawals would be stuck for ever if no
  next round opens (ticker paused, chip refused).
- Per LP accounting is lazy: the processing step stores one conversion rate per queue (`EpochRate`), and
  each LP's entry is booked the next time that LP (or anyone, through `settle`) touches it. `positionOf`
  shows the settled view without a transaction. Processing is O(1), so `pullRoundCapital` cannot be made
  to run out of gas by a long queue.
- `cancelDeposit` lets an LP take a still-queued deposit back during the round. A queued deposit has no
  exposure, so this gives no option value; it is a safety valve if a round never returns.
- There is no `cancelWithdraw`: queued shares bear the round's result either way.

### 1.3 Split of a round's result

At `returnRoundCapital`, with `sent = lpAssets + endowment` at lock time and `received` what came back:
- `lpAssets = floor(received * lpAssets / sent)`, the endowment gets the rest (rounding to the endowment);
- this holds for a profit and for a loss alike: both sides gain or lose the same fraction;
- donations made during the round join the endowment after the result, so they take no part in it.

**Why symmetric.** An endowment that takes losses first while profits are shared pro rata can be farmed:
an LP who also bets against its own house keeps the whole win, paid by the endowment, and gets most of a
lost bet back through its own shares (an expected gain of about a fifth of the endowment per round). With
a symmetric split the same bet has a negative expected value for the LP as well. The endowment is
permanent, non-withdrawable capital that deepens the house; it is not insurance for LPs.

A chip that starts to tax its transfers after its house was funded loses its tax twice per round (out and
back); that is booked as a loss like any other, shared pro rata.

### 1.4 Price 0 and share generations

- After a total loss the shares stay on the ledger, transfer, and redeem for 0.
- When new capital arrives (a deposit, or the queue), those shares are **void**: the house starts a new
  share generation at the opening price and `balanceOf` reads the new generation. Event `SharesVoided`.
  **Reason:** with the virtual offset alone, a deposit into `lpAssets == 0, totalShares == S` mints
  `amount * (S + 1e6)` shares. The previous holders would keep a claim of about `1 / amount` of the pool
  (dust), and the supply would grow by a factor of `amount` per wipeout: three wipeouts overflow `uint256`
  and brick the house. Voiding is the same economic result without the overflow.
- **Dust floor.** If a round leaves fewer than `totalShares / 1e18` chip units behind the shares (a price
  drop of 1e12 from the opening price), the remainder joins the endowment and the shares price at 0. The
  same when capital is left with no shares outstanding. This keeps `totalShares <= about 1e18 * lpAssets`,
  so no mint can overflow. The amount moved is at most 1e-12 of what those shares were minted for. It is
  the only place where LP-owned units move to the endowment.

### 1.5 Inflows, outflows, stray chips

- `deposit` and `donate` measure `balance after - balance before` around their own `transferFrom`, add
  that to `accounted[chip]`, and revert with `InexactTransfer(sent, received)` unless it equals the amount
  sent. `returnRoundCapital` credits `balance - accounted[chip]` (the hook transfers first, then calls).
- **No fee-on-transfer chips.** A taxed chip would make every path (the router's gross-up, the tax on
  every payout, the inbox's double tax) one more thing to get wrong, for a house that loses 2% a round.
  The guard refuses a flagged chip and the vault refuses a short inflow, so an unflagged tax chip gets a
  house that can never be funded. The measured credit stays: it costs nothing and keeps the books right if
  a chip changes its behaviour later. The same check refuses a chip that delivers more than was sent.
- Chips sent straight to the vault are never credited to a depositor; they are booked as part of the
  next round result of that chip (they benefit a house, and nobody can skim them).
- **Requirement on the hook:** transfer the chips to the vault and call `returnRoundCapital` in the same
  transaction. Two houses of one chip returning in two steps each would otherwise mix their results.
- Every outflow sends the nominal amount and takes it off the books (what the receiver gets from a chip
  that taxes is the receiver's matter).
- A failing `balanceOf` reverts instead of reading as 0. This is the only way `returnRoundCapital` can
  revert for the hook; a zero or short return never does.
- Every state-changing function shares one transient reentrancy guard.

### 1.6 Privileges

- No owner, no pause, no upgrade, no sweep. The only privileged caller is the immutable `hook`.
- The hook can only take `lpAssets + endowment` of an unlocked house and must bring it back through
  `returnRoundCapital`. It cannot touch queued deposits, queued donations or claimable withdrawals.
- **Risk:** a hook that never calls `returnRoundCapital` leaves the house locked and its capital outside
  for ever. There is no emergency exit, by design. Queued deposits can still be cancelled and processed
  withdrawals can still be claimed.
- **Acting for an owner.** `depositFor(house, amount, owner)`, `cancelDepositFor(house, owner)`,
  `requestWithdrawFor(house, shares, owner)` and `claimFor(house, owner)` do what the plain LP functions
  do, for `owner`. Callers: `owner` itself, an ERC-6909 operator of `owner` (`setOperator`), or the
  router, `router()`, which is read from the immutable hook (`hook.router()`, itself immutable), so no
  setter exists. The router calls them only for session-signed `VaultOp`s
  (`FallpitRouter.vaultWithSig`), with the signed user as `owner`. A deposit pulls the chips from the
  caller (the router pulls them from the user first); shares, a cancelled deposit, a withdrawal paid
  at once and a claim are booked and paid to `owner`, never to the caller. `owner` zero or the vault
  itself is refused (`InvalidReceiver`).
- **What an operator can do (wider than ERC-6909).** In plain ERC-6909 an operator (`setOperator`) can
  move all of the owner's shares of every house (`transferFrom`). Here it can also, for the owner and in
  every house: deposit its own chips as the owner's shares, cancel the owner's queued deposits, request
  withdrawals of the owner's shares (paid at once or queued) and claim the owner's processed withdrawals.
  These four calls pay only the owner, so they move no value to the operator, but they change the
  owner's position against the owner's will: a deposit is taken out of the queue, shares leave the
  house at a time the owner did not choose, a queued withdrawal keeps bearing the round. Grant operator
  approval only to a contract you trust with all your shares. The owner ends it with
  `setOperator(spender, false)`. There is no separate agent approval, by design.
- **What the router can do.** The router acts only on a `VaultOp` signed by a session key of `owner`
  whose grant has the vault scope (`SCOPE_VAULT`), with each deposit at most the grant's `maxPerOrder`
  and all deposits of the session at most its `maxTotal` per chip. A withdrawal or claim can carry a
  `minOut` (for a withdrawal: only when it pays that much at once, so it never queues). A stolen session
  key with the vault scope can still withdraw the owner's shares to the owner, so an app should grant the
  vault scope only when the user uses the vault.
- **Deployment order.** `hook` is immutable in the vault and the hook needs the vault. The vault's address
  is known from the deployer's nonce, and the hook's from its init code: it is created through the
  deterministic deployment proxy with a fixed salt. So the vault is deployed with the hook's address, then
  the hook (`script/FallpitDeployer.sol`, which checks `vault.hook() == hook`).

### 1.7 Risk limits live in the hook

Bankroll controls such as per-bet liability reservation, a loss cap per fill or a payout multiple that
tightens with utilisation are risk limits on trades. In Fallpit they belong to the hook (per-fill cap,
pooled solvency check, loss limit) and the vault stays a ledger. The one such idea in the vault is the
two-step exit: withdrawals during a round wait for the result.

## 2. ChipGuard

### 2.1 What identifies each template on chain (Robinhood Chain 4663)

Method: `eth_getCode` and `eth_call` over 272 pairable coins, then the fork test
`test/vault/fork/ChipGuard.fork.t.sol` on a sample.

| Template | Coins checked | Identifier | Result |
|---|---|---|---|
| Doppler coin (long.xyz, Bankr, other Doppler launches) | 192 | `extcodehash` | **All 192 share one hash** `0xf10f86b05965a827a332e6c73086f18026fbe3917f4bffbec3f938b3b5397b56`. Runtime code is the 44-byte minimal clone `3d3d3d3d363d3d37363d73 <impl> 5af43d3d93803e602a57fd5bf3` of `0x3Be8B97Fd0e713B5aBE0649Fa830223B6B4BC599` (solady `LibClone`). |
| Pons v2 coin | 47 | factory lookup | Same size (3,248 bytes) but **47 distinct code hashes** (constructor immutables: factory, curve, deployer). The factory `0x7eD598BcEf8bd9Edd8C97A195C6d13f40801EC7e` answers `getLaunchedToken(address)` (selector `0x3cf28b5a`) with a record whose first word is the coin itself; all zero for any other address. All 47 are found, none of the other 225 coins is. |
| Pons v1 coin `0x39dB...4571` | 1 | none trusted | 5,274 bytes, own factory `0x0c37a24F5D23A486FA692d1500881d698B1F77a4`, unknown to the Pons v2 factory. Needs owner approval. |
| USDG `0x5fc5...d168` | 1 | none trusted | 170-byte proxy. Needs owner approval. |
| Other templates and contracts, stock tokens | 33 | none trusted | Need owner approval per coin. |

- The coin's own `launchFactory()` getter proves nothing (any contract can return the Pons factory), so the
  guard asks the factory, never the coin.
- The Doppler clone hash commits to the implementation address. The implementation is not upgradeable.
  On another chain (testnet 46630) the implementation address and therefore the hash differ; set it per
  chain.

### 2.2 Design

`check(chip)` returns `allowed` when the chip is not refused, is not flagged `feeOnTransfer`, has code,
`decimals() <= 18`, has no active Doppler balance limit, and is trusted by one of three routes: trusted
code hash, trusted registry lookup, or owner approval.

- `setTrustedRegistry(target, selector, matchKind)` is generic: `ReturnsChip` (first return word equals
  the coin address, the Pons v2 shape) or `ReturnsTrue` (a boolean `isToken(address)` style getter). At
  most 8 registries.
- `approve`, `refuse` and `setFeeOnTransfer` take `(chip, bool)` so each can be undone. A refusal beats
  every route, and so does the `feeOnTransfer` flag: a flagged chip is never allowed. `check` still
  returns the flag as its second value.
- The balance limit rule applies to every chip, including owner-approved ones: the guard calls
  `isBalanceLimitActive()` and blocks the coin when it answers true. Coins without the function pass.
- Reads of the coin and of registries are static calls with a 200,000 gas cap that copy one word (no
  return bomb). `check` reverts with `InsufficientGas` when it cannot forward the full cap, so a caller
  cannot starve the balance-limit read into "no limit".
- The owner can only edit the lists. The guard holds no funds and the vault only consults it in
  `createHouse`; refusing a chip later does not affect deposits, withdrawals or claims of existing houses.
- Pons v2 coins that are still on their bonding curve are known to the factory and therefore allowed.
- `feeOnTransfer` is an owner-set flag; nothing on chain verifies it. The vault does not depend on it: it
  measures every inflow and refuses one that arrives short, so an unflagged tax chip is stopped at
  `deposit` and `donate` (and by the router at `commit`).

## 3. CommunityTreasury

### 3.1 One fee inbox per house

With one shared fee address, the **caller** of `harvest` would pick the house, so anyone could route a
community's fees to any house of that chip (for example a house where they are the only LP). Doppler gives
the receiver no way to learn which beneficiary redirected which share, so the treasury could not check the
caller's choice.

So every house has a `PitFeeInbox` at a fixed CREATE2 address, `inboxOf(house)`, known before it is
deployed. The community sets **that inbox** as beneficiary. The choice of inbox is the choice of house,
and it is made by the one party entitled to make it.

- `harvest(feesManager, poolId, house)`: the inbox calls `collectFees(poolId)`, then donates its whole chip
  balance to `PitVault.donate(house, ...)`; the other pool token stays in the inbox. Both legs are measured
  by balance.
- `sweep(house)`: donates chips that reached the inbox outside a harvest. This happens in practice:
  Doppler's `updateBeneficiary` pays the new beneficiary's pending fees during the call, a Rehype
  `buybackDst` pushes on swaps, and people send tokens by hand.
- `feesManager` is an untrusted argument. Whatever it does, the inbox's chips can only move into its own
  house, and reentry into the treasury is blocked. Any Doppler contract that inherits `FeesManager` works
  (DopplerHookInitializer, StreamableFeesLockerV2, RehypeDopplerHookInitializer).
- Harvesting during a round queues the donation; it joins the endowment after the round's result.

### 3.2 Owner

`releaseOtherLeg(house, token, to, amount)` moves a token that is **not** the house's chip out of the
inbox (the stock token leg, or the native coin). The chip leg has no path but the house: the test
`test_owner_cannotMoveTheChipLeg` and the fork test `testFork_owner_cannotTakeTheChipLeg` cover it. The
owner of the treasury should be a multisig.

### 3.3 The live Doppler contracts (fork test `test/vault/fork/CommunityTreasury.fork.t.sol`)

- The fork test runs against the real contracts: AI / NVDA pool
  `0xcbdfea90430a30ee4469c9902e120a77e7c7e4711d5643671c1d1957f2f1ce27` on the DopplerHookInitializer
  `0x4e3468951D49f2EEa976eD0D6e75fFCb44a9a544`, status `Locked`, `currency0 = AI`, `currency1 = NVDA`
  stock token. It impersonates the live 95% beneficiary, calls `updateBeneficiary(poolId, inbox)`, and
  harvests. One harvest moved about 19,067 AI into the house and 5.93 NVDA stock tokens into the inbox. A
  second test sells 1,000,000 AI inside the fork and sees 95% of the 0.7% fee (about 6,649 AI) arrive.
- **`getBeneficiaries(asset)` is the launch record and goes stale.** Read live shares with
  `getShares(poolId, address)`; an app must not show `getBeneficiaries`.
- The deployed FeesManager has no `CallerNotBeneficiary` check, so anyone may call `updateBeneficiary`
  and a caller without shares simply moves nothing; Doppler's current source adds the check. The mock
  (`test/vault/mocks/MockFeesManager.sol`) models both (`strict` flag) and the treasury works with both.
- `updateBeneficiary` moves **all** of the caller's shares. A community that wants to give only part of
  its fees needs a splitter contract in front.
- The inbox is a plain address that accepts transfers, so any launchpad that can pay a contract address
  can use it with `sweep`.

## 4. Tests

- `test/vault/PitVault.t.sol`: every case of SPEC section 5, plus reentrancy through a hostile chip, the
  share ledger, two houses on one chip, stray chips, fuzz of the split and of the share price, a tax chip
  refused at `createHouse` (flagged) and at `deposit` and `donate` (unflagged), and a chip that starts to
  tax after its house was funded.
- `test/vault/PitVault.invariant.t.sol`: stateful fuzz over four houses on two chips (one plain, one that
  the run switches between plain and a 1% tax), four LPs, random round results including 0 and dust;
  while the tax is on every inflow of that chip must be refused and change nothing. It runs with
  `fail-on-revert`, so a bricked function fails it.
- `test/vault/ChipGuard.t.sol`, `test/vault/CommunityTreasury.t.sol`: unit tests with mocks.
- `test/vault/fork/*.t.sol`: read-only fork tests on chain 4663, skipped unless `FORK_RPC_4663` is set.
