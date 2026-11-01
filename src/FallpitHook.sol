// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {ERC6909} from "solady/tokens/ERC6909.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

import {IFallpitHook, RefundReason} from "./interfaces/IFallpitHook.sol";
import {ILadderMath} from "./interfaces/ILadderMath.sol";
import {IPitOracle} from "./interfaces/IPitOracle.sol";
import {IPitVault} from "./interfaces/IPitVault.sol";
import {IChipGuard} from "./interfaces/IChipGuard.sol";
import {IPitBook} from "./hook/IPitBook.sol";
import {PackedBands} from "./lib/PackedBands.sol";
import {PitMath} from "./hook/PitMath.sol";
import {HouseBands, OpenDeps, Round, RoundLogic, StoredState} from "./hook/RoundLogic.sol";

/// @title FallpitHook
/// @notice The Fallpit daily stock-close game. Every round is a menu of products (up to twelve at the open:
///         floors of the close and the HIGHER / LOWER pair; up to fifteen with its live strikes), each an ERC-6909 ticket of this contract on a run of
///         bands (id = round id | product index, `tokenId`), all priced from one joint band state by
///         `ILadderMath`. See contracts/SPEC.md section 7.
/// @dev The chips of every round sit in this contract. `chipOwed` is what it must hold per chip: every
///      round's `held` plus `protocolFeesAccrued`; anything above it belongs to nobody. So do tickets sent to
///      this contract or to the router (outside the router's escrow): nothing can move them out again. Fills come only
///      from the immutable router, which attests the user and the fill instant from its commit record.
///      Closes, volatility, the calendar, the clock, default parameters and the roles live in the immutable
///      `PitBook`; a round copies what it needs when it opens, its clock included, and asks the book only
///      to evaluate that frozen clock (`clockAt`, a pure function). This contract has no owner: nobody can move user or
///      house funds, and nothing is upgradeable. The one input to an open round after it opens is the book's vol
///      keeper's learned sigma (`setSigmaEff`), bounded by the book (`PitBook.stepSigmaEff`: 0.8x to 1.5x of the
///      round's sigma, at most 10% per update and one update per 5 minutes, all rises of a round at most 1.5x).
contract FallpitHook is IFallpitHook, ERC6909 {
    using FixedPointMathLib for uint256;
    using SafeTransferLib for address;

    /// @dev One fill being priced (`_fill`): the round, the product index, the side, the ticket count, the
    ///      trader and the commit instant, then the price and time of the print for that instant.
    struct Order {
        bytes32 roundId;
        uint8 index;
        bool isBuy;
        uint256 shares;
        address user;
        uint64 t;
        uint256 price;
        uint64 ts;
    }

    uint256 private constant WAD = 1e18;
    uint256 private constant BPS = 10_000;
    /// @dev A round with no recorded close can be voided this long after its close.
    /// @dev The low byte of a round id, where a ticket id carries its product index.
    uint256 private constant INDEX_MASK = 0xff;
    /// @dev Transient slot of the reentrancy lock ("FallpitLock").
    uint256 private constant LOCK_SLOT = 0x46616c6c7069744c6f636b;
    /// @dev Transient slot of the hook's own ETH at the start of a fill ("FallpitKept").
    uint256 private constant KEPT_SLOT = 0x46616c6c7069744b657074;

    /// @inheritdoc IFallpitHook
    address public immutable router;
    ILadderMath public immutable math;
    IPitOracle public immutable oracle;
    IPitVault public immutable vault;
    IChipGuard public immutable chipGuard;
    /// @inheritdoc IFallpitHook
    IPitBook public immutable book;

    mapping(bytes32 roundId => Round) internal _rounds;
    /// @notice Latest round of a house (0 when none).
    mapping(bytes32 house => bytes32 roundId) public houseRound;
    /// @notice Protocol fees of finalized rounds waiting for `collectProtocolFees`.
    mapping(address chip => uint256) public protocolFeesAccrued;
    /// @notice Chips this contract must hold: every round's `held` plus `protocolFeesAccrued`.
    mapping(address chip => uint256) public chipOwed;
    /// @dev The open depths' part that depends on sigma alone (`ILadderMath.openLnInv`) of the house's
    ///      latest round, written over at each open (10 slots a house, not 40 new ones a round). A round's
    ///      depths are `math.depths` of it with the round's capital and alpha. Only the latest round of a
    ///      house trades, and settling, finalizing, voiding and redeeming never read the depths; so an older
    ///      round's depths are not kept (`getCurve` returns zero depths for it).
    mapping(bytes32 house => uint256[10] packed) internal _lnInv;
    /// @dev The pricing state of each house's latest traded round (`RoundLogic.HouseBands`): an older
    ///      round's state is not kept (`getCurve` returns the zero state for it once the next round traded).
    mapping(bytes32 house => HouseBands) internal _bands;

    modifier onlyRouter() {
        if (msg.sender != router) revert OnlyRouter();
        _;
    }

    modifier nonReentrant() {
        if (_locked()) revert Reentrancy();
        _setLock(1);
        _;
        _setLock(0);
    }

    /// @param router_ the two-step router; its address is fixed forever
    constructor(
        address router_,
        ILadderMath math_,
        IPitOracle oracle_,
        IPitVault vault_,
        IChipGuard chipGuard_,
        IPitBook book_
    ) {
        if (
            router_ == address(0) || address(math_) == address(0) || address(oracle_) == address(0)
                || address(vault_) == address(0) || address(chipGuard_) == address(0)
                || address(book_) == address(0)
        ) revert ZeroAddress();
        router = router_;
        math = math_;
        oracle = oracle_;
        vault = vault_;
        chipGuard = chipGuard_;
        book = book_;
    }

    /// @notice Accepts the oracle's refunds only. A fill or a strike sends the oracle its own `msg.value`,
    ///         and what comes back goes to the filler or the caller in the same call, so the hook keeps no
    ///         ETH; ETH from anyone else would have no way out.
    receive() external payable {
        if (msg.sender != address(oracle)) revert EthNotAccepted();
    }

    // ------------------------------------------------------------------------------------------------
    // Fills and escrow
    // ------------------------------------------------------------------------------------------------

    /// @inheritdoc IFallpitHook
    function fill(
        bytes32 roundId,
        uint8 product,
        bool isBuy,
        uint256 shares,
        uint256 limit,
        address user,
        uint64 t,
        bytes calldata report
    ) external payable onlyRouter nonReentrant returns (uint256 chips) {
        if (shares == 0 || shares > uint128(type(int128).max)) revert ZeroAmount();
        address chip = _rounds[roundId].cfg.chip;
        {
            // transient: the hook's own ETH before this call, so only this call's spare ETH goes back
            uint256 kept = address(this).balance - msg.value;
            assembly ("memory-safe") {
                tstore(KEPT_SLOT, kept)
            }
        }
        Order memory o = Order(roundId, product, isBuy, shares, user, t, 0, 0);
        if (isBuy) {
            // the router sent the escrow first: it must be here on top of what is owed already
            // a low-level read: a chip's own revert data never comes out of a fill (it could pose as a final
            // rejection); a failed read counts as nothing here, so the fill is not final either
            if (SafeTransferLib.balanceOf(chip, address(this)) < chipOwed[chip] + limit) revert ChipShort();
            (chips,) = _fill(o, report);
            if (chips > limit) revert FillRejected(uint8(RefundReason.Limit));
            _mint(user, tokenId(roundId, product), shares);
            if (limit > chips) chip.safeTransfer(user, limit - chips);
        } else {
            (chips,) = _fill(o, report);
            if (chips < limit) revert FillRejected(uint8(RefundReason.Limit));
            _burn(router, tokenId(roundId, product), shares);
            if (chips != 0) chip.safeTransfer(user, chips);
        }
        // the filler's ETH above the oracle's fee goes back through the router (msg.value only paid the
        // oracle; the hook's own ETH stays out of it)
        _returnEth();
    }

    /// @dev Sends the router what the oracle sent back of this call's ETH.
    function _returnEth() private {
        uint256 back = address(this).balance;
        uint256 kept;
        assembly ("memory-safe") {
            kept := tload(KEPT_SLOT)
        }
        if (back > kept) router.safeTransferETH(back - kept);
    }

    /// @inheritdoc IFallpitHook
    function pull(address from, uint256 id, uint256 amount) external onlyRouter {
        _transfer(address(0), from, router, id, amount);
    }

    // ------------------------------------------------------------------------------------------------
    // Lifecycle
    // ------------------------------------------------------------------------------------------------

    /// @inheritdoc IFallpitHook
    /// @dev The book decides whether a round may open (not paused, a day with a round, the close it starts
    ///      from recorded) and supplies S0, sigma, the clock and the parameters, all frozen here. A round
    ///      may open as soon as that close is recorded and the house's previous round is over: it then
    ///      trades in every window of its clock, the after-hours of the day before included. A previous
    ///      round that is still open because its close was missed (not recorded `PitClock.MISSED_CLOSE`
    ///      after its instant) does not block the house: it is voided here, as `voidRound` would void it
    ///      24 hours after its close, so the next day still has its round. A close recorded after that
    ///      point is late and settles nothing (`PitBook.closeState` shows none), so it does not stop the void.
    function openRound(bytes32 ticker, address chip, uint32 day)
        external
        nonReentrant
        returns (bytes32 roundId)
    {
        return RoundLogic.start(
            _rounds,
            houseRound,
            chipOwed,
            _lnInv,
            OpenDeps({book: book, chipGuard: chipGuard, vault: vault, math: math}),
            ticker,
            chip,
            day
        );
    }

    /// @inheritdoc IFallpitHook
    /// @dev The print is checked as a fill's is (the oracle's print for `t`, the round's fill source); the
    ///      rules are in `RoundLogic.openStrike`.
    function openStrike(bytes32 roundId, uint8 m, uint64 t, bytes calldata report)
        external
        payable
        nonReentrant
    {
        Round storage r = _rounds[roundId];
        if (r.st.status != Status.Open) revert WrongStatus();
        {
            // the instant is at most the refund window and at most STRIKE_MAX_LAG old
            uint256 lag = r.cfg.params.refundDelay;
            if (lag > PitMath.STRIKE_MAX_LAG) lag = PitMath.STRIKE_MAX_LAG;
            if (t > block.timestamp || block.timestamp > uint256(t) + lag) revert FillExpired();
        }
        uint256 sigmaEff = sigmaEffOf(roundId);
        // the caller pays the oracle's fee: the hook's own ETH stays out of it, and what the oracle does not
        // spend goes back to the caller
        uint256 kept = address(this).balance - msg.value;
        (uint256 price, uint64 ts) = _verify(r.cfg, t, report, msg.value);
        RoundLogic.openStrike(r, roundId, m, price, ts, sigmaEff, book);
        if (address(this).balance > kept) msg.sender.safeTransferETH(address(this).balance - kept);
    }

    /// @inheritdoc IFallpitHook
    /// @dev The book checks the caller and the rate and applies the bounds (`PitBook.stepSigmaEff`); the hook
    ///      keeps the result for its fills. An update moves prices with no trade, as the clock does.
    function setSigmaEff(bytes32 roundId, uint256 sigmaEff) external {
        RoundLogic.setSigmaEff(_rounds[roundId], roundId, sigmaEff, book);
    }

    /// @inheritdoc IFallpitHook
    function sigmaEffOf(bytes32 roundId) public view returns (uint256) {
        Round storage r = _rounds[roundId];
        uint256 s = r.st.sigmaEff;
        return s == 0 ? r.cfg.sigma : s;
    }

    /// @inheritdoc IFallpitHook
    /// @dev Once the close is recorded in time (a late close settles nothing: `PitBook.closeState`). A
    ///      product wins when its run of bands contains the close's band. A settled round can be settled
    ///      again only after its close was replaced by a trustless print.
    function settleRound(bytes32 house, uint32 day) external nonReentrant {
        bytes32 roundId = roundIdOf(house, day);
        RoundLogic.settle(_rounds[roundId], roundId, day, book);
    }

    /// @inheritdoc IFallpitHook
    /// @dev Immediately when the close is trustless, otherwise after the challenge window and, when the
    ///      guardian disputed the close (`PitBook.dispute`), after the dispute. Keeps the winners' payout
    ///      and the protocol fees as claims and sends the rest to the vault.
    function finalizeRound(bytes32 house, uint32 day) external nonReentrant {
        bytes32 roundId = roundIdOf(house, day);
        RoundLogic.finalize(_rounds[roundId], roundId, house, day, book, vault, protocolFeesAccrued, chipOwed);
    }

    /// @inheritdoc IFallpitHook
    /// @dev Anyone, when an open round has no recorded close 24 h after its close (a late close counts as
    ///      none: `PitBook.closeState`). Nothing else voids a
    ///      round (a settled round cannot be voided: a wrong keeper close is disputed in the book and
    ///      replaced, never voided). The house comes first: it gets back the capital it brought, as far as
    ///      the round still holds it. What the round holds above that is what traders as a group still
    ///      have in it, and the outstanding tokens share it pro rata to their cost basis, each capped at
    ///      its cost basis (fees included). So a void never pays the house's capital to anyone: chips that
    ///      sellers already took out are not owed again to the holders who remain. Refunds are per token,
    ///      not per buyer: every holder of one token gets the same amount per token, whatever each of them
    ///      paid.
    function voidRound(bytes32 house, uint32 day) external nonReentrant {
        bytes32 roundId = roundIdOf(house, day);
        RoundLogic.voidRound(_rounds[roundId], roundId, day, book, vault, chipOwed);
    }

    /// @inheritdoc IFallpitHook
    /// @dev Callable by the holder, or by the router on behalf of its own caller. After Final a token of a
    ///      winning product pays one chip; after Void every token pays its product's average cost. No
    ///      oracle, fee or deadline.
    function redeem(uint256 id, address holder, uint256 amount)
        external
        nonReentrant
        returns (uint256 payout)
    {
        if (msg.sender != holder && msg.sender != router) revert NotHolder();
        if (amount == 0) revert ZeroAmount();
        (bytes32 roundId, uint8 index) = tokenRef(id);
        Round storage r = _rounds[roundId];
        if (r.st.status == Status.None || index >= PitMath.count(r.cfg.params.menu)) revert UnknownToken();
        payout = RoundLogic.redeem(r, index, amount);
        address chip = r.cfg.chip;
        chipOwed[chip] -= payout;

        _burn(holder, id, amount);
        _pay(chip, holder, payout);
        emit Redeemed(roundId, id, holder, amount, payout);
    }

    /// @inheritdoc IFallpitHook
    function collectProtocolFees(address chip) external nonReentrant returns (uint256 amount) {
        return RoundLogic.collectProtocolFees(chip, book, protocolFeesAccrued, chipOwed);
    }

    // ------------------------------------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------------------------------------

    /// @inheritdoc IFallpitHook
    function commitContext(bytes32 roundId, uint8 product)
        external
        view
        returns (
            uint256 id,
            address chip,
            bool tradable,
            uint32 fillDelay,
            uint32 refundDelay,
            uint256 minShares,
            uint64 fillFee,
            bool isOpen
        )
    {
        Round storage r = _rounds[roundId];
        RoundConfig storage c = r.cfg;
        // the round's smallest trade in the token's own units, rounded up, at least one unit
        minShares = uint256(c.params.minTrade).divUp(10 ** (18 - c.decimals));
        // a commit made now is priced at now + fillDelay: that instant must be inside a trading window
        (, tradable) = book.clockAt(c.clock, uint64(block.timestamp) + c.params.fillDelay);
        return (
            r.st.status != Status.None && product < PitMath.count(c.params.menu)
                ? tokenId(roundId, product)
                : 0,
            c.chip,
            tradable,
            c.params.fillDelay,
            c.params.refundDelay,
            minShares == 0 ? 1 : minShares,
            c.params.fillFee,
            r.st.status == Status.Open
        );
    }

    /// @inheritdoc IFallpitHook
    function houseOf(bytes32 ticker, address chip) public pure returns (bytes32) {
        return keccak256(abi.encode(ticker, chip));
    }

    /// @inheritdoc IFallpitHook
    function roundIdOf(bytes32 house, uint32 day) public pure returns (bytes32) {
        return bytes32(uint256(keccak256(abi.encode(house, day))) & ~INDEX_MASK);
    }

    /// @inheritdoc IFallpitHook
    function tokenId(bytes32 roundId, uint8 product) public pure returns (uint256) {
        return uint256(roundId) | product;
    }

    /// @inheritdoc IFallpitHook
    function tokenRef(uint256 id) public pure returns (bytes32 roundId, uint8 index) {
        return (bytes32(id & ~INDEX_MASK), uint8(id & INDEX_MASK));
    }

    /// @inheritdoc IFallpitHook
    function getConfig(bytes32 roundId) external view returns (RoundConfig memory) {
        return _rounds[roundId].cfg;
    }

    /// @inheritdoc IFallpitHook
    function getState(bytes32 roundId) external view returns (RoundState memory) {
        StoredState storage t = _rounds[roundId].st;
        return RoundState({
            status: t.status,
            settledTrustless: t.settledTrustless,
            closeBand: t.closeBand,
            winners: t.winners,
            settledAt: t.settledAt,
            g: t.g,
            held: t.held,
            protocolFees: t.protocolFees,
            payoutOwed: t.payoutOwed,
            settledPrice: t.settledPrice
        });
    }

    /// @inheritdoc IFallpitHook
    function getSupplies(bytes32 roundId)
        external
        view
        returns (uint256[15] memory supply, uint256[15] memory premium)
    {
        Round storage r = _rounds[roundId];
        for (uint256 i; i < PitMath.MAX_PRODUCTS; ++i) {
            (supply[i], premium[i]) = (r.supply[i], r.premium[i]);
        }
    }

    /// @inheritdoc IFallpitHook
    function seedOf(bytes32 roundId) external view returns (int256) {
        HouseBands storage b = _bands[_rounds[roundId].cfg.house];
        return b.tag == _bandTag(roundId) ? b.lambda : int256(0);
    }

    /// @inheritdoc IFallpitHook
    function getCurve(bytes32 roundId) external view returns (int256[40] memory v, uint256[40] memory b0) {
        Round storage r = _rounds[roundId];
        if (r.st.status != Status.None && houseRound[r.cfg.house] == roundId) b0 = _depthsOf(r.cfg);
        HouseBands storage hb = _bands[r.cfg.house];
        if (hb.tag == _bandTag(roundId)) v = PackedBands.load(hb.v);
    }

    /// @notice ERC-6909 metadata: one name for every ticket; the id says which round and product.
    function name(uint256) public pure override returns (string memory) {
        return "Fallpit ticket";
    }

    function symbol(uint256) public pure override returns (string memory) {
        return "PITTIX";
    }

    /// @notice A ticket has its round's chip decimals: one winning ticket pays one chip.
    function decimals(uint256 id) public view override returns (uint8) {
        (bytes32 roundId,) = tokenRef(id);
        return _rounds[roundId].cfg.decimals;
    }

    function tokenURI(uint256) public pure override returns (string memory) {
        return "";
    }

    // ------------------------------------------------------------------------------------------------
    // Internals
    // ------------------------------------------------------------------------------------------------

    /// @dev Prices one fill and writes the round's new state. Returns the chips the trader pays (buy) or
    ///      receives (sell) and the fee inside them.
    function _fill(Order memory o, bytes calldata report) private returns (uint256 chips, uint256 fee) {
        Round storage r = _rounds[o.roundId];
        ILadderMath.PackedFill memory f;
        {
            (uint8 lo, uint8 hi) = _checkFill(r, o);
            uint256 rho;
            (o.price, o.ts, rho) = _print(r.cfg, o.t, report);
            f = _engine(r, o, lo, hi, rho);
        }
        (chips, fee) = _account(r, o, f);
        emit Filled(o.roundId, o.user, o.index, o.isBuy, o.shares, chips, fee, o.price, o.ts);
    }

    /// @dev The checks of a fill that come before its print. Returns the product's band run.
    function _checkFill(Round storage r, Order memory o) private view returns (uint8 lo, uint8 hi) {
        RoundConfig storage c = r.cfg;
        if (o.index >= PitMath.count(c.params.menu)) revert UnknownToken();
        (lo, hi) = PitMath.run(c.params.menu, o.index);
        if (r.st.status != Status.Open) revert FillRejected(uint8(RefundReason.NotOpen));
        if (o.shares > c.maxFill) revert FillRejected(uint8(RefundReason.Cap));
        // A floor's outstanding supply is capped at a share of the round's capital.
        if (o.isBuy && PitMath.overCap(lo, hi, r.supply[o.index] + o.shares, c.capital, c.params.floorCapBps))
        {
            revert FillRejected(uint8(RefundReason.ProductCap));
        }
        if (block.timestamp > uint256(o.t) + c.params.refundDelay) revert FillExpired();
    }

    /// @dev The one print that counts for instant t (the oracle reverts on any other report), checked
    ///      against the round's fill source and clock. Returns the price, its time and the share of the
    ///      round's variance still ahead at that time.
    function _print(RoundConfig storage c, uint64 t, bytes calldata report)
        private
        returns (uint256 price, uint64 ts, uint256 rho)
    {
        (price, ts) = _verify(c, t, report, msg.value);
        // The round's clock at the print: how much of its variance is still ahead, and whether it trades.
        bool tradable;
        (rho, tradable) = book.clockAt(c.clock, ts);
        if (!tradable) revert FillRejected(uint8(RefundReason.Window));
    }

    /// @dev The oracle's print for instant t, of the round's fill source; `value` pays the oracle's fee.
    function _verify(RoundConfig storage c, uint64 t, bytes calldata report, uint256 value)
        private
        returns (uint256 price, uint64 ts)
    {
        bool trustless;
        // The oracle calls outside contracts (Pyth, a Chainlink aggregator, a stock token) that can be
        // upgraded. Their revert data must never pose as a final rejection (`FillRejected`), which the
        // router turns into a refund: such data comes out as `OracleReverted`, which is not final.
        try oracle.verifyAt{value: value}(c.ticker, t, report) returns (uint256 p, uint64 at, bool tl) {
            (price, ts, trustless) = (p, at, tl);
        } catch (bytes memory err) {
            if (err.length >= 4 && bytes4(err) == FillRejected.selector) revert OracleReverted();
            assembly ("memory-safe") {
                revert(add(err, 0x20), mload(err))
            }
        }
        if (price == 0) revert BadPrice();
        // A round is priced by one source: a print of the other source is not the print for t.
        if ((c.fillSource == IPitBook.FillSource.TrustlessOnly) != trustless) revert WrongFillSource();
    }

    /// @dev Runs the engine for the fill, stores the new band state and depth scale, and takes the fill's
    ///      risk from the budget of its print.
    function _engine(Round storage r, Order memory o, uint8 lo, uint8 hi, uint256 rho)
        private
        returns (ILadderMath.PackedFill memory f)
    {
        // The remaining sd and the vega use the learned sigma; the bands stay on the frozen one.
        ILadderMath.Ctx memory ctx;
        (ctx.x, ctx.sd, ctx.gNew) = PitMath.context(sigmaEffOf(o.roundId), rho, r.cfg.s0, o.price, r.st.g);
        ctx.gOld = r.st.g;
        int256 delta = int256(o.shares * 10 ** (18 - r.cfg.decimals));
        f = _solveFill(r, o.roundId, ctx, lo, hi, o.isBuy ? delta : -delta);
        r.st.g = uint64(ctx.gNew); // at most the stored g (`PitMath.context`), so at most 1e18
        // The risk budget of the print: every fill priced by the print of ts (every commit instant in
        // (prevTs, ts]) shares capital * riskCapBps * gNew, gNew the depth scale at ts
        // (`PitMath.riskBudget`). A buy risks what the house pays beyond the premium (shares - amount), a
        // sell the chips it pays out. The book keeps the sum of the round's latest print (PitBook.takeRisk,
        // PitBook.riskUsed).
        if (!book.takeRisk(
                o.roundId,
                o.ts,
                o.isBuy ? (uint256(delta) > f.amount ? uint256(delta) - f.amount : 0) : f.amount,
                PitMath.riskBudget(r.cfg.capital, r.cfg.decimals, r.cfg.params.riskCapBps, ctx.gNew)
            )) revert FillRejected(uint8(RefundReason.Cap));
    }

    /// @dev The engine's fill on the round's stored state, seeded with the last fill's root; stores the new
    ///      state and its root in the house's slots (tagged with the round on its first fill).
    function _solveFill(
        Round storage r,
        bytes32 roundId,
        ILadderMath.Ctx memory ctx,
        uint8 lo,
        uint8 hi,
        int256 delta
    ) private returns (ILadderMath.PackedFill memory f) {
        HouseBands storage b = _bands[r.cfg.house];
        uint128 tag = _bandTag(roundId);
        bool mine = b.tag == tag;
        // before its first fill a round has the zero state, whose root is exactly 0 (the prior sums to 1e18)
        f = math.fillPacked(_packedIn(r, b, mine), ctx, lo, hi, delta, mine ? b.lambda : int256(0));
        (b.tag, b.lambda) = (tag, SafeCastLib.toInt128(f.lambda));
        b.v = f.v;
    }

    /// @dev The tag of a round's pricing state in its house's slots (`RoundLogic.HouseBands`).
    function _bandTag(bytes32 roundId) private pure returns (uint128) {
        return uint128(uint256(roundId) >> 128);
    }

    /// @dev The engine's inputs for a fill of the round: its packed state (zero before its first fill) and
    ///      what its depths come from.
    function _packedIn(Round storage r, HouseBands storage b, bool mine)
        private
        view
        returns (ILadderMath.PackedIn memory a)
    {
        RoundConfig storage c = r.cfg;
        if (mine) a.v = b.v;
        a.lnInv = _lnInv[c.house];
        a.capital = c.capital * 10 ** (18 - c.decimals);
        a.alpha = c.params.alpha;
        a.sigma = c.sigma;
    }

    /// @dev Charges or pays the fill with its fees, moves the supply, cost basis and chips, and runs the
    ///      round's pooled solvency and loss limit check.
    function _account(Round storage r, Order memory o, ILadderMath.PackedFill memory f)
        private
        returns (uint256 chips, uint256 fee)
    {
        {
            RoundConfig storage c = r.cfg;
            uint256 scale = 10 ** (18 - c.decimals);
            uint256 rate =
                PitMath.feeRate(c.params.baseFee, c.params.closeFee, c.params.feeRamp, c.closeTs, o.ts);
            uint256 vegaPerShare = uint256(c.params.vegaFee).mulWadUp(f.vega); // against the trader
            if (o.isBuy) {
                (chips, fee) =
                    PitMath.buyCost(f.amount, scale, o.shares, rate, vegaPerShare, c.params.minPriceWad);
            } else {
                (chips, fee) = PitMath.sellProceeds(f.amount, scale, o.shares, rate, vegaPerShare);
            }
        }
        uint256 held = _move(r, o, chips);
        uint256 protocolFees = r.st.protocolFees + fee * r.cfg.params.protocolFeeBps / BPS;
        r.st.protocolFees = SafeCastLib.toUint128(protocolFees);

        // Pooled solvency: the worst band's payout plus the protocol's fees must be covered. And the
        // round's loss limit: a buy must leave the house a set part of its capital in that worst band.
        uint256 menu = r.cfg.params.menu;
        RefundReason reason = PitMath.postFillCheck(
            PitMath.supplyOf(r.supply, menu),
            menu,
            held,
            protocolFees,
            r.cfg.capital,
            r.cfg.params.lossLimitBps,
            o.isBuy
        );
        if (reason != RefundReason.None) revert FillRejected(uint8(reason));
    }

    /// @dev Moves a fill's tickets and chips in the round's books. Returns the chips the round holds after it.
    ///      Supply and premium are 128-bit (`RoundLogic.Round`). The checked add on a buy and `toUint128`
    ///      revert rather than wrap, and no real chip reaches them: every winning ticket must stay covered
    ///      by `held` (`PitMath.postFillCheck`), the capital is at most 1e33 wei (the engine's depth check at
    ///      the open), so supply and premium stay many orders of magnitude below 2^128 (3.4e38). Such a revert
    ///      is not a refund reason: the commit waits for `refund`.
    function _move(Round storage r, Order memory o, uint256 chips) private returns (uint256 held) {
        address chip = r.cfg.chip;
        uint8 index = o.index;
        held = r.st.held;
        if (o.isBuy) {
            // shares fit 127 bits (`fill`); the sums revert past 128 bits
            r.supply[index] += uint128(o.shares);
            r.premium[index] = SafeCastLib.toUint128(r.premium[index] + chips);
            held += chips;
            chipOwed[chip] += chips;
        } else {
            if (chips > held) revert FillRejected(uint8(RefundReason.Solvency));
            // The sold shares take their average cost with them (rounded up), and never less than the
            // chips they are paid: otherwise buying high and selling back would inflate the cost basis
            // that a void refunds, at the house's expense.
            uint256 premium = r.premium[index];
            uint256 leaving = premium.fullMulDivUp(o.shares, r.supply[index]);
            if (leaving < chips) leaving = chips;
            r.premium[index] = uint128(leaving < premium ? premium - leaving : 0);
            r.supply[index] -= uint128(o.shares);
            held -= chips;
            chipOwed[chip] -= chips;
        }
        r.st.held = SafeCastLib.toUint128(held);
    }

    /// @dev The opening depths of a round: alpha * capital / lnInv per band (`ILadderMath.depths`).
    function _depthsOf(RoundConfig storage c) private view returns (uint256[40] memory) {
        return math.depths(_lnInv[c.house], c.capital * 10 ** (18 - c.decimals), c.params.alpha);
    }

    /// @dev Sends `amount` chips of the contract's own to `to`; the caller has taken it off `chipOwed`.
    function _pay(address chip, address to, uint256 amount) private {
        if (amount != 0) chip.safeTransfer(to, amount);
    }

    function _locked() private view returns (bool locked) {
        assembly ("memory-safe") {
            locked := tload(LOCK_SLOT)
        }
    }

    function _setLock(uint256 value) private {
        assembly ("memory-safe") {
            tstore(LOCK_SLOT, value)
        }
    }
}
