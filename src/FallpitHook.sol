// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {ERC6909} from "solady/tokens/ERC6909.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

import {IFallpitHook, RefundReason} from "./interfaces/IFallpitHook.sol";
import {ILadderMath} from "./interfaces/ILadderMath.sol";
import {IPitOracle} from "./interfaces/IPitOracle.sol";
import {IPitVault} from "./interfaces/IPitVault.sol";
import {IChipGuard} from "./interfaces/IChipGuard.sol";
import {IPitBook} from "./hook/IPitBook.sol";
import {NYTime} from "./lib/NYTime.sol";
import {PackedBands} from "./lib/PackedBands.sol";
import {PitMath} from "./hook/PitMath.sol";
import {PitClock} from "./hook/PitClock.sol";

/// @dev What the hook reads from a chip directly.
interface IChipDecimals {
    function decimals() external view returns (uint8);
    function balanceOf(address owner) external view returns (uint256);
}

/// @title FallpitHook
/// @notice The Fallpit daily stock-close game. Every round is a menu of products (up to twelve: floors
///         of the close and the HIGHER / LOWER pair), each an ERC-6909 ticket of this contract on a run of
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

    /// @dev One round: frozen config, pricing state and the supply and premium of each product of its menu
    ///      (`cfg.params.menu`; the entries above the last product stay zero). `v` is the band state of
    ///      `ILadderMath` packed two bands to a word (`PackedBands`). The packing is exact: `ILadderMath`
    ///      rejects any |v_j| above 1e36 on the way in and on the way out, and 1e36 < 2^127.
    struct Round {
        RoundConfig cfg;
        RoundState st;
        uint256[12] supply;
        uint256[12] premium;
        uint256[20] v;
    }

    uint256 private constant WAD = 1e18;
    uint256 private constant BPS = 10_000;
    /// @dev A round with no recorded close can be voided this long after its close.
    uint64 private constant VOID_AFTER = 24 hours;
    /// @dev The low byte of a round id, where a ticket id carries its product index.
    uint256 private constant INDEX_MASK = 0xff;
    /// @dev Transient slot of the reentrancy lock ("FallpitLock").
    uint256 private constant LOCK_SLOT = 0x46616c6c7069744c6f636b;

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
    /// @dev The learned sigma of a round (`setSigmaEff`); zero until the first update.
    mapping(bytes32 roundId => uint256) internal _sigmaEff;

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

    /// @notice Accepts ETH to pay oracle update fees on fills (today the fee is 0). The oracle's refunds
    ///         land here and pay for later fills. Nobody can withdraw it.
    receive() external payable {}

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
        uint256 id = tokenId(roundId, product);
        if (isBuy) {
            // the router sent the escrow first: it must be here on top of what is owed already
            // a low-level read: a chip's own revert data never comes out of a fill (it could pose as a final
            // rejection); a failed read counts as nothing here, so the fill is not final either
            if (SafeTransferLib.balanceOf(chip, address(this)) < chipOwed[chip] + limit) revert ChipShort();
            uint256 fee;
            (chips, fee) = _fill(roundId, product, true, shares, user, t, report);
            if (chips > limit) revert FillRejected(uint8(RefundReason.Limit));
            _mint(user, id, shares);
            if (limit > chips) chip.safeTransfer(user, limit - chips);
        } else {
            (chips,) = _fill(roundId, product, false, shares, user, t, report);
            if (chips < limit) revert FillRejected(uint8(RefundReason.Limit));
            _burn(router, id, shares);
            if (chips != 0) chip.safeTransfer(user, chips);
        }
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
        (
            uint256 s0,
            uint256 sigma,
            IPitBook.RoundClock memory clock,
            IPitBook.FillSource fillSource,
            IPitBook.Params memory p
        ) = book.openTerms(ticker, day);
        uint64 closeAt = NYTime.closeTs(day);
        if (block.timestamp >= closeAt - PitClock.CUTOFF_LEAD) revert TooLate();
        (bool allowed,) = chipGuard.check(chip);
        if (!allowed) revert ChipNotAllowed();
        uint8 chipDecimals = IChipDecimals(chip).decimals();
        if (chipDecimals > 18) revert ChipNotAllowed();

        bytes32 house = houseOf(ticker, chip);
        {
            bytes32 previous = houseRound[house];
            if (previous != bytes32(0)) {
                Round storage pr = _rounds[previous];
                Status s = pr.st.status;
                if (s == Status.Open) {
                    (uint256 price,,) = book.closeState(ticker, pr.cfg.day);
                    if (price != 0 || block.timestamp <= pr.cfg.closeTs + PitClock.MISSED_CLOSE) {
                        revert PreviousRoundActive();
                    }
                    _void(pr, previous);
                } else if (s == Status.Settled) {
                    revert PreviousRoundActive();
                }
            }
        }
        roundId = roundIdOf(house, day);
        Round storage r = _rounds[roundId];
        if (r.st.status != Status.None) revert RoundExists();

        // Everything that does not depend on the capital is written before the capital is pulled.
        houseRound[house] = roundId;
        r.st.status = Status.Open;
        r.st.g = WAD;
        RoundConfig storage c = r.cfg;
        c.ticker = ticker;
        c.house = house;
        c.chip = chip;
        c.day = day;
        c.decimals = chipDecimals;
        c.fillSource = fillSource;
        c.openTs = uint64(block.timestamp);
        c.closeTs = closeAt;
        c.cutoff = closeAt - PitClock.CUTOFF_LEAD;
        c.clock = clock;
        c.s0 = s0;
        c.sigma = sigma;
        c.params = p;

        // Pull the house capital; L is what actually arrived.
        uint256 before = IChipDecimals(chip).balanceOf(address(this));
        vault.pullRoundCapital(house, address(this));
        uint256 capital = IChipDecimals(chip).balanceOf(address(this)) - before;
        if (capital < uint256(p.minCapital) * 10 ** chipDecimals) revert CapitalTooLow();
        c.capital = capital;
        c.maxFill = capital * p.maxFillBps / BPS;
        r.st.held = capital;
        chipOwed[chip] += capital;
        // the depths are checked here and derived again at each fill (`_depthsOf`)
        uint256[10] memory packed = math.openLnInv(sigma);
        math.depths(packed, capital * 10 ** (18 - chipDecimals), p.alpha);
        _lnInv[house] = packed;

        emit RoundOpened(roundId, ticker, chip, day, s0, sigma, capital, p.menu);
    }

    /// @inheritdoc IFallpitHook
    /// @dev The book checks the caller and the rate and applies the bounds (`PitBook.stepSigmaEff`); the hook
    ///      keeps the result for its fills. An update moves prices with no trade, as the clock does.
    function setSigmaEff(bytes32 roundId, uint256 sigmaEff) external {
        Round storage r = _rounds[roundId];
        if (r.st.status != Status.Open) revert WrongStatus();
        sigmaEff = book.stepSigmaEff(msg.sender, roundId, r.cfg.sigma, sigmaEff);
        _sigmaEff[roundId] = sigmaEff;
        emit SigmaEffSet(roundId, sigmaEff);
    }

    /// @inheritdoc IFallpitHook
    function sigmaEffOf(bytes32 roundId) public view returns (uint256) {
        uint256 s = _sigmaEff[roundId];
        return s == 0 ? _rounds[roundId].cfg.sigma : s;
    }

    /// @inheritdoc IFallpitHook
    /// @dev Once the close is recorded in time (a late close settles nothing: `PitBook.closeState`). A
    ///      product wins when its run of bands contains the close's band. A settled round can be settled
    ///      again only after its close was replaced by a trustless print.
    function settleRound(bytes32 house, uint32 day) external nonReentrant {
        bytes32 roundId = roundIdOf(house, day);
        Round storage r = _rounds[roundId];
        RoundConfig storage c = r.cfg;
        RoundState storage st = r.st;
        Status s = st.status;
        if (s != Status.Open && s != Status.Settled) revert WrongStatus();
        (uint256 price, bool trustless,) = book.closeState(c.ticker, day);
        if (price == 0) revert CloseNotRecorded();
        if (s == Status.Settled) {
            if (price == st.settledPrice && trustless == st.settledTrustless) revert AlreadySettled();
        } else {
            st.settledAt = uint64(block.timestamp);
        }

        uint8 band = math.bandOf(c.sigma, FixedPointMathLib.lnWad(int256(price.divWad(c.s0))));
        uint16 mask = PitMath.winners(c.params.menu, band);
        uint256 payout = PitMath.payoutOf(r.supply, mask);
        st.status = Status.Settled;
        st.closeBand = band;
        st.winners = mask;
        st.payoutOwed = payout;
        st.settledPrice = price;
        st.settledTrustless = trustless;
        emit RoundSettled(roundId, price, band, mask, payout, trustless);
    }

    /// @inheritdoc IFallpitHook
    /// @dev Immediately when the close is trustless, otherwise after the challenge window and, when the
    ///      guardian disputed the close (`PitBook.dispute`), after the dispute. Keeps the winners' payout
    ///      and the protocol fees as claims and sends the rest to the vault.
    function finalizeRound(bytes32 house, uint32 day) external nonReentrant {
        bytes32 roundId = roundIdOf(house, day);
        Round storage r = _rounds[roundId];
        RoundConfig storage c = r.cfg;
        RoundState storage st = r.st;
        if (st.status != Status.Settled) revert WrongStatus();
        (uint256 price, bool trustless, uint64 disputeEnd) = book.closeState(c.ticker, day);
        if (price != st.settledPrice) revert CloseChanged();
        if (
            !trustless
                && (block.timestamp < st.settledAt + c.params.challengeWindow || block.timestamp < disputeEnd)
        ) {
            revert ChallengeWindowOpen();
        }

        uint256 payout = st.payoutOwed;
        uint256 fees = st.protocolFees;
        uint256 back = st.held - payout - fees;
        st.status = Status.Final;
        st.held = payout;
        st.protocolFees = 0;
        address chip = c.chip;
        protocolFeesAccrued[chip] += fees;
        chipOwed[chip] -= back;

        _pay(chip, address(vault), back);
        vault.returnRoundCapital(house);
        emit RoundFinalized(roundId, payout, fees, back);
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
        Round storage r = _rounds[roundId];
        if (r.st.status != Status.Open) revert WrongStatus();
        (uint256 price,,) = book.closeState(r.cfg.ticker, day);
        if (block.timestamp <= r.cfg.closeTs + VOID_AFTER || price != 0) revert VoidNotAllowed();
        _void(r, roundId);
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
        RoundState storage st = r.st;
        if (st.status == Status.Final) {
            if (st.winners >> index & 1 == 0) revert NotWinner();
            payout = amount;
        } else if (st.status == Status.Void) {
            payout = r.premium[index].fullMulDiv(amount, r.supply[index]);
            r.premium[index] -= payout;
        } else {
            revert WrongStatus();
        }
        r.supply[index] -= amount;
        st.held -= payout;
        st.payoutOwed -= payout;
        address chip = r.cfg.chip;
        chipOwed[chip] -= payout;

        _burn(holder, id, amount);
        _pay(chip, holder, payout);
        emit Redeemed(roundId, id, holder, amount, payout);
    }

    /// @inheritdoc IFallpitHook
    function collectProtocolFees(address chip) external nonReentrant returns (uint256 amount) {
        address to = book.feeRecipient();
        if (to == address(0)) revert ZeroAddress();
        amount = protocolFeesAccrued[chip];
        protocolFeesAccrued[chip] = 0;
        chipOwed[chip] -= amount;
        _pay(chip, to, amount);
        emit ProtocolFeesCollected(chip, to, amount);
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
        return _rounds[roundId].st;
    }

    /// @inheritdoc IFallpitHook
    function getSupplies(bytes32 roundId)
        external
        view
        returns (uint256[12] memory supply, uint256[12] memory premium)
    {
        Round storage r = _rounds[roundId];
        return (r.supply, r.premium);
    }

    /// @inheritdoc IFallpitHook
    function getCurve(bytes32 roundId) external view returns (int256[40] memory v, uint256[40] memory b0) {
        Round storage r = _rounds[roundId];
        if (r.st.status != Status.None && houseRound[r.cfg.house] == roundId) b0 = _depthsOf(r.cfg);
        return (PackedBands.load(r.v), b0);
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
    function _fill(
        bytes32 roundId,
        uint8 index,
        bool isBuy,
        uint256 shares,
        address user,
        uint64 t,
        bytes calldata report
    ) private returns (uint256 chips, uint256 fee) {
        Round storage r = _rounds[roundId];
        RoundConfig storage c = r.cfg;
        RoundState storage st = r.st;
        address chip = c.chip;

        if (index >= PitMath.count(c.params.menu)) revert UnknownToken();
        (uint8 lo, uint8 hi) = PitMath.run(c.params.menu, index);
        if (st.status != Status.Open) revert FillRejected(uint8(RefundReason.NotOpen));
        if (shares > c.maxFill) revert FillRejected(uint8(RefundReason.Cap));
        // A floor's outstanding supply is capped at a share of the round's capital.
        if (isBuy && PitMath.overCap(lo, hi, r.supply[index] + shares, c.capital, c.params.floorCapBps)) {
            revert FillRejected(uint8(RefundReason.ProductCap));
        }
        if (block.timestamp > uint256(t) + c.params.refundDelay) revert FillExpired();

        // The one print that counts for instant t; the oracle reverts on any other report.
        (uint256 price, uint64 ts, bool trustless) =
            oracle.verifyAt{value: address(this).balance}(c.ticker, t, report);
        if (price == 0) revert BadPrice();
        // A round is priced by one source: a print of the other source is not the print for t.
        if ((c.fillSource == IPitBook.FillSource.TrustlessOnly) != trustless) revert WrongFillSource();
        // The round's clock at the print: how much of its variance is still ahead, and whether it trades.
        (uint256 rho, bool tradable) = book.clockAt(c.clock, ts);
        if (!tradable) revert FillRejected(uint8(RefundReason.Window));

        uint256 scale = 10 ** (18 - c.decimals);
        ILadderMath.Fill memory f;
        {
            // The remaining sd and the vega use the learned sigma; the bands stay on the frozen one.
            (int256 x, uint256 sd, uint256 gNew) =
                PitMath.context(sigmaEffOf(roundId), rho, c.s0, price, st.g);
            int256 delta = int256(shares * scale);
            f = math.fill(
                PackedBands.load(r.v),
                _depthsOf(c),
                c.sigma,
                ILadderMath.Ctx({x: x, sd: sd, gOld: st.g, gNew: gNew}),
                lo,
                hi,
                isBuy ? delta : -delta
            );
            PackedBands.store(r.v, f.v);
            st.g = gNew;
            // The risk budget of the print: every fill priced by the print of ts (every commit instant in
            // (prevTs, ts]) shares capital * riskCapBps * gNew, gNew the depth scale at ts
            // (`PitMath.riskBudget`). A buy risks what the house pays beyond the premium (shares - amount), a
            // sell the chips it pays out. The book keeps the sums (PitBook.takeRisk, PitBook.riskUsed), keyed
            // by ts.
            if (!book.takeRisk(
                    roundId,
                    ts,
                    isBuy ? (uint256(delta) > f.amount ? uint256(delta) - f.amount : 0) : f.amount,
                    PitMath.riskBudget(c.capital, c.decimals, c.params.riskCapBps, gNew)
                )) revert FillRejected(uint8(RefundReason.Cap));
        }

        uint256 rate = PitMath.feeRate(c.params.baseFee, c.params.closeFee, c.params.feeRamp, c.closeTs, ts);
        uint256 vegaPerShare = uint256(c.params.vegaFee).mulWad(f.vega);
        uint256 held = st.held;
        if (isBuy) {
            (chips, fee) = PitMath.buyCost(f.amount, scale, shares, rate, vegaPerShare, c.params.minPriceWad);
            r.supply[index] += shares;
            r.premium[index] += chips;
            held += chips;
            chipOwed[chip] += chips;
        } else {
            (chips, fee) = PitMath.sellProceeds(f.amount, scale, shares, rate, vegaPerShare);
            if (chips > held) revert FillRejected(uint8(RefundReason.Solvency));
            // The sold shares take their average cost with them (rounded up), and never less than the
            // chips they are paid: otherwise buying high and selling back would inflate the cost basis
            // that a void refunds, at the house's expense.
            uint256 premium = r.premium[index];
            uint256 leaving = premium.fullMulDivUp(shares, r.supply[index]);
            if (leaving < chips) leaving = chips;
            r.premium[index] = leaving < premium ? premium - leaving : 0;
            r.supply[index] -= shares;
            held -= chips;
            chipOwed[chip] -= chips;
        }
        st.held = held;
        uint256 protocolFees = st.protocolFees + fee * c.params.protocolFeeBps / BPS;
        st.protocolFees = protocolFees;

        // Pooled solvency: the worst band's payout plus the protocol's fees must be covered. And the
        // round's loss limit: a buy must leave the house a set part of its capital in that worst band.
        RefundReason reason = PitMath.postFillCheck(
            r.supply, c.params.menu, held, protocolFees, c.capital, c.params.lossLimitBps, isBuy
        );
        if (reason != RefundReason.None) revert FillRejected(uint8(reason));
        emit Filled(roundId, user, index, isBuy, shares, chips, fee, price, ts);
    }

    /// @dev Voids an open round (see `voidRound`): the house first, then the holders pro rata to their cost.
    function _void(Round storage r, bytes32 roundId) private {
        RoundConfig storage c = r.cfg;
        RoundState storage st = r.st;
        uint256 held = st.held;
        uint256 refundable = held > c.capital ? held - c.capital : 0;
        uint256 refunds;
        for (uint256 i; i < PitMath.MAX_PRODUCTS; ++i) {
            refunds += r.premium[i];
        }
        if (refunds > refundable) {
            uint256 total = refunds;
            refunds = 0;
            for (uint256 i; i < PitMath.MAX_PRODUCTS; ++i) {
                uint256 scaled = r.premium[i].fullMulDiv(refundable, total);
                r.premium[i] = scaled;
                refunds += scaled;
            }
        }
        uint256 back = held - refunds;
        st.status = Status.Void;
        st.held = refunds;
        st.payoutOwed = refunds;
        st.protocolFees = 0;
        address chip = c.chip;
        chipOwed[chip] -= back;

        _pay(chip, address(vault), back);
        vault.returnRoundCapital(c.house);
        emit RoundVoided(roundId, refunds, back);
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
