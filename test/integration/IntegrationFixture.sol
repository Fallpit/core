// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Accounting} from "../Accounting.sol";

import {PoolManager} from "v4-core/PoolManager.sol";
import {CustomRevert} from "v4-core/libraries/CustomRevert.sol";

import {FallpitDeployer} from "../../script/FallpitDeployer.sol";
import {LadderMath} from "../../src/LadderMath.sol";
import {PitOracle} from "../../src/PitOracle.sol";
import {ChipGuard} from "../../src/ChipGuard.sol";
import {PitVault} from "../../src/PitVault.sol";
import {PitLister} from "../../src/listing/PitLister.sol";
import {CommunityTreasury} from "../../src/CommunityTreasury.sol";
import {FallpitHook} from "../../src/FallpitHook.sol";
import {FallpitRouter} from "../../src/FallpitRouter.sol";
import {Ticket, ticketsOf, ticketOf} from "../Ticket.sol";
import {PitBook} from "../../src/hook/PitBook.sol";
import {IPitBook} from "../../src/hook/IPitBook.sol";
import {FallpitLens} from "../../src/hook/FallpitLens.sol";
import {FallpitDirectory} from "../../src/hook/FallpitDirectory.sol";
import {PitMath} from "../../src/hook/PitMath.sol";
import {IFallpitHook} from "../../src/interfaces/IFallpitHook.sol";
import {IFallpitRouter} from "../../src/interfaces/IFallpitRouter.sol";
import {NYTime} from "../../src/lib/NYTime.sol";
import {MirrorFeed, MirrorStockToken} from "../../src/testnet/MirrorFeed.sol";

import {OracleTestBase} from "../oracle/OracleTestBase.sol";
import {MockPyth} from "../oracle/mocks/MockPyth.sol";
import {MockChip, MockFeeChip} from "../hook/mocks/MockChips.sol";
import {StandardMenu} from "../Menus.sol";

/// @notice The whole system with nothing mocked but the outside world: the real LadderMath, PitOracle,
///         ChipGuard, PitVault, PitBook, FallpitRouter, FallpitHook (created through the CREATE2 factory),
///         FallpitLens and CommunityTreasury, with a local v4 PoolManager for the router's ETH pools,
///         deployed and wired by the same `FallpitDeployer` code the testnet deploy script runs. Outside the system: a mock Pyth core
///         contract, MirrorFeed aggregators pushed by the keeper, and test chips.
/// @dev Two tickers cover both oracle paths.
///      - NVDA: `KeeperOnly`. Fills use 2-of-3 keeper-signed prints bounded by its MirrorFeed. It also has
///        a Pyth feed id, so a trustless close can replace a keeper close.
///      - TSLA: `TrustlessOnly`. Fills use Pyth updates.
///      Rounds open with the book's default menu (`StandardMenu` has its product indices) unless a test
///      sets another.
///      The keeper prints once a second: the print at `ts` carries `prevTs = ts - 1`, so exactly one print
///      qualifies for an instant. Prices are kept on Pyth's grid (multiples of 1e13 wei) so that the
///      same price can be served by either source.
abstract contract IntegrationFixture is OracleTestBase, FallpitDeployer, StandardMenu {
    bytes32 internal constant NVDA = bytes32("NVDA");
    bytes32 internal constant TSLA_ID = 0x16dad506d7db8da01c87581c87ca897a012a153557d4d578c3b9c9e1bc0632f1;
    bytes32 internal constant NVDA_ID = 0xb1073854ed24cbc755dc527418f52b7d271f6cc967bbf8d8129112b18860a593;
    bytes32 internal constant ETH = bytes32("ETH");
    bytes32 internal constant ETH_ID = 0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace;

    uint8 internal constant PYTH_SOURCE = 1;
    uint8 internal constant KEEPER_SOURCE = 2;

    uint256 internal constant S0 = 180e18;
    uint256 internal constant TSLA_S0 = 370.65e18;
    uint256 internal constant SEED_VAR = 0.0004e18; // sigma = 2%
    uint256 internal constant HOUSE_CAPITAL = 1_000_000e18;
    /// @dev The book's default fill fee: what every commit carries unless a test sets other parameters.
    uint256 internal constant FILL_FEE = 0.0001 ether;
    /// @dev Pyth prices here have 5 decimals: one unit is 1e13 wei of WAD.
    uint256 internal constant PRICE_GRID = 1e13;

    PoolManager internal pm;
    LadderMath internal math;
    PitOracle internal oracle;
    ChipGuard internal guard;
    PitVault internal vault;
    PitLister internal lister;
    CommunityTreasury internal treasury;
    PitBook internal book;
    FallpitRouter internal router;
    FallpitHook internal hook;
    FallpitLens internal lens;
    FallpitDirectory internal directory;
    MockPyth internal pyth;
    MockChip internal chip;
    MockFeeChip internal taxChip;

    mapping(bytes32 ticker => MirrorFeed) internal feedOf;
    mapping(bytes32 ticker => MirrorStockToken) internal stockTokenOf;
    mapping(bytes32 ticker => bytes32) internal pythIdOf;

    address internal owner = makeAddr("owner");
    address internal guardian = makeAddr("guardian");
    address internal feeRecipient = makeAddr("feeRecipient");
    address internal keeper = makeAddr("keeper");
    address internal lp = makeAddr("lp");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    /// @dev Monday 2026-10-05 (its close is recorded in `setUp`) and Tuesday 2026-10-06.
    uint32 internal day0;
    uint32 internal day;
    /// @dev The round the helpers act on.
    bytes32 internal ticker;
    address internal roundChip;
    bytes32 internal house;
    bytes32 internal roundId;
    /// @dev Absolute clock; tests never use `block.timestamp + x` (unreliable under via-IR).
    uint64 internal clock;
    mapping(bytes32 ticker => mapping(uint64 ts => bytes)) internal _keeperPrints;
    mapping(bytes32 ticker => mapping(uint64 ts => bytes)) internal _pythPrints;

    function setUp() public virtual {
        day0 = uint32(NYTime.daysFromCivil(2026, 10, 5));
        day = day0 + 1;
        // start the clock well before Monday's close so mirror rounds can be dated in the past, and a day
        // before it so that the tickers and the guardian (24 hours each) are in force by Monday's close
        _warp(NYTime.closeTs(day0) - 25 hours);

        pm = new PoolManager(address(this));
        pyth = new MockPyth();
        _makeSigners(3);
        Core memory d = _deployCore(
            CoreConfig({
                poolManager: address(pm),
                pyth: address(pyth),
                owner: owner,
                signers: signerAddrs,
                threshold: 2,
                ownerDelay: 24 hours,
                signerDelay: 24 hours
            }),
            address(this)
        );
        math = d.math;
        oracle = d.oracle;
        guard = d.guard;
        vault = d.vault;
        lister = d.lister;
        treasury = d.treasury;
        book = d.book;
        router = d.router;
        hook = d.hook;
        lens = d.lens;
        directory = d.directory;

        chip = new MockChip(18);
        taxChip = new MockFeeChip();
        vm.startPrank(owner);
        guard.approve(address(chip), true);
        // approved, not flagged: the tax coin the guard does not know about (a flagged one gets no house)
        guard.approve(address(taxChip), true);
        _addTicker(NVDA, NVDA_ID, IPitBook.FillSource.KeeperOnly);
        _addTicker(TSLA, TSLA_ID, IPitBook.FillSource.TrustlessOnly);
        book.setGuardian(guardian);
        book.setFeeRecipient(feeRecipient);
        // the risk budget per print second is tested on its own (RiskBudget.t.sol); elsewhere it stays out
        // of the way so each suite measures its own mechanism with several fills in one second. The suites
        // use a per-fill cap of 2% of the capital (the book's default is 20%, a loose ceiling under the
        // budget; DeployTestnetScript.t.sol checks the real defaults).
        IPitBook.Params memory p = book.defaultParams();
        p.riskCapBps = _testRiskCapBps();
        p.maxFillBps = 200;
        book.setDefaultParams(p);
        vm.stopPrank();

        // Monday's closes: NVDA from the keeper set, TSLA from Pyth
        uint64 close0 = NYTime.closeTs(day0);
        _warp(close0 + 60);
        book.recordClose(NVDA, day0, _keeperPrint(NVDA, S0, close0));
        book.recordClose(TSLA, day0, _pythPrint(TSLA, TSLA_S0, close0));

        // the default round: NVDA in the plain chip, one LP
        ticker = NVDA;
        roundChip = address(chip);
        house = _createHouse(NVDA, address(chip));
        _lpDeposit(lp, house, HOUSE_CAPITAL);
    }

    /// @dev Creates a house by the lister's owner route (no anchor check, no seed).
    function _createHouse(bytes32 ticker_, address chip_) internal returns (bytes32) {
        vm.prank(owner);
        return lister.createHouse(ticker_, chip_);
    }

    /// @dev Registers a stock (the `NYWeekdays` clock with the book's default weights). Call as the owner.
    function _addTicker(bytes32 ticker_, bytes32 pythId, IPitBook.FillSource source) internal {
        _addTickerOn(ticker_, pythId, IPitBook.Clock.NYWeekdays, source);
    }

    /// @dev Registers a ticker in the oracle (Pyth id plus a keeper-pushed mirror feed and stock token
    ///      stub) and in the book, on the given clock with its default weights. Call as the owner.
    function _addTickerOn(bytes32 ticker_, bytes32 pythId, IPitBook.Clock kind, IPitBook.FillSource source)
        internal
    {
        _addTickerWith(ticker_, pythId, kind, 0, source);
    }

    /// @dev The same with the ticker's trading windows given (0: the clock's default).
    function _addTickerWith(
        bytes32 ticker_,
        bytes32 pythId,
        IPitBook.Clock kind,
        uint8 windows,
        IPitBook.FillSource source
    ) internal {
        MirrorFeed feed = new MirrorFeed(8, "mirror", owner, keeper);
        MirrorStockToken token = new MirrorStockToken(feed, 1e18);
        feedOf[ticker_] = feed;
        stockTokenOf[ticker_] = token;
        pythIdOf[ticker_] = pythId;
        PitOracle.TickerConfig memory c;
        c.pythFeedId = pythId;
        c.aggregator = address(feed);
        c.stockToken = address(token);
        oracle.setTicker(ticker_, c);
        // a new ticker is in force 24 hours after its registration: the owner registered it a day ago
        vm.warp(clock - 24 hours);
        book.registerTicker(ticker_, SEED_VAR, kind, IPitBook.Weights(0, 0, 0, 0), windows, source);
        vm.warp(clock);
    }

    // ------------------------------------------------------------------------------------------ clock

    function _warp(uint64 to) internal {
        require(to >= clock, "clock goes forward");
        clock = to;
        vm.warp(to);
    }

    /// @dev New default parameters, in force now: the owner announced them 24 hours ago. (The book makes
    ///      every change of the defaults wait 24 hours; a test that needs other parameters for the round
    ///      it is about to open has the owner make the announcement a day earlier.)
    function _setParams(IPitBook.Params memory p) internal {
        vm.warp(clock - 24 hours);
        vm.prank(owner);
        book.setDefaultParams(p);
        vm.warp(clock);
    }

    /// @dev Another menu for the rounds opened from now on (the owner announced it 24 hours ago).
    function _setMenu(uint256 menu) internal {
        IPitBook.Params memory p = book.defaultParams();
        p.menu = menu;
        _setParams(p);
    }

    // ---------------------------------------------------------------------------------------- oracles

    /// @dev `price` rounded down to Pyth's grid.
    function _grid(uint256 price) internal pure returns (uint256) {
        return price / PRICE_GRID * PRICE_GRID;
    }

    /// @dev Copies a "mainnet" round into the ticker's mirror feed when the price has left the 0.5% band
    ///      of the last round or the last round is a day old, as the real push feed would. A round can only be dated at or after the
    ///      previous one and not in the future; otherwise the rounds already there stand.
    function _mirror(bytes32 ticker_, uint256 price, uint64 ts) internal {
        MirrorFeed feed = feedOf[ticker_];
        (, int256 answer,, uint256 updatedAt,) = feed.latestRoundData();
        uint256 target = price * stockTokenOf[ticker_].uiMultiplier() / 1e18 / 1e10;
        if (answer != 0) {
            uint256 last = uint256(answer);
            uint256 diff = target > last ? target - last : last - target;
            // inside the band the feed still reports once a day (its heartbeat)
            if (ts < updatedAt || (diff * 10_000 <= last * 50 && ts - updatedAt < 1 days)) return;
        }
        if (ts > clock) return;
        vm.prank(keeper);
        feed.push(int256(target), ts);
    }

    /// @dev The keeper's print for `ts` (signed by signers 0 and 1), created at `price` when none exists
    ///      for that second yet. One print per second and ticker: later calls return the same print.
    function _keeperPrint(bytes32 ticker_, uint256 price, uint64 ts) internal returns (bytes memory report) {
        report = _keeperPrints[ticker_][ts];
        if (report.length == 0) {
            price = _grid(price);
            _mirror(ticker_, price, ts);
            report = _signedPrint(ticker_, price, ts, ts - 1);
            _keeperPrints[ticker_][ts] = report;
        }
    }

    /// @dev A 2-of-3 signed print with any content (also for prints the honest keeper would never make).
    function _signedPrint(bytes32 ticker_, uint256 price, uint64 ts, uint64 prevTs)
        internal
        view
        returns (bytes memory)
    {
        return
            _report2(oracle, PitOracle.Print({ticker: ticker_, price: price, ts: ts, prevTs: prevTs}), 0, 1);
    }

    /// @dev The Pyth update published at `ts` (previous update one second earlier), created at `price`
    ///      when none exists for that second yet.
    function _pythPrint(bytes32 ticker_, uint256 price, uint64 ts) internal returns (bytes memory report) {
        report = _pythPrints[ticker_][ts];
        if (report.length == 0) {
            report = _pythUpdate(pythIdOf[ticker_], price, ts, ts - 1);
            _pythPrints[ticker_][ts] = report;
        }
    }

    function _pythUpdate(bytes32 id, uint256 price, uint64 ts, uint64 prevTs)
        internal
        view
        returns (bytes memory)
    {
        int64 p = int64(uint64(price / PRICE_GRID));
        return _pythReport(pyth.encode(id, p, uint64(p) / 5000, -5, ts, prevTs));
    }

    /// @dev The print that prices fills of the current round at `ts`: the source its ticker is pinned to.
    function _print(uint64 ts, uint256 price) internal returns (bytes memory) {
        return hook.getConfig(roundId).fillSource == IPitBook.FillSource.TrustlessOnly
            ? _pythPrint(ticker, price, ts)
            : _keeperPrint(ticker, price, ts);
    }

    // ----------------------------------------------------------------------------------------- houses

    function _lpDeposit(address who, bytes32 house_, uint256 amount) internal returns (uint256 shares) {
        address chip_ = vault.chipOf(house_);
        MockChip(chip_).mint(who, amount);
        vm.startPrank(who);
        MockChip(chip_).approve(address(vault), amount);
        shares = vault.deposit(house_, amount);
        vm.stopPrank();
    }

    /// @dev Points the helpers at the house of (ticker, chip), creating it when needed.
    function _use(bytes32 ticker_, address chip_) internal {
        ticker = ticker_;
        roundChip = chip_;
        house = vault.houseId(ticker_, chip_);
        if (vault.chipOf(house) == address(0)) _createHouse(ticker_, chip_);
        roundId = hook.houseRound(house);
    }

    // ----------------------------------------------------------------------------------------- rounds

    /// @dev Opens the current house's round for `day` and moves the clock one minute into the regular
    ///      session (09:31 New York). The round is opened where the clock stands, as the keeper opens it:
    ///      a minute after the previous close unless the test moved on.
    function _open() internal returns (bytes32) {
        roundId = hook.openRound(ticker, roundChip, day);
        _warp(NYTime.openTs(day) + 60);
        return roundId;
    }

    /// @dev Opens the current house's round for `day` where the clock stands and stays there, one minute
    ///      on: in the after-hours of the day before when the test did not move the clock (16:02 New
    ///      York, nearly the whole variance of the round still ahead).
    function _openAfterHours() internal returns (bytes32) {
        roundId = hook.openRound(ticker, roundChip, day);
        _warp(clock + 60);
        return roundId;
    }

    /// @dev Chips to trade with, and ETH for the fill fees of the commits.
    function _fund(address user, uint256 amount) internal {
        vm.deal(user, 10 ether);
        MockChip(roundChip).mint(user, amount);
        vm.prank(user);
        MockChip(roundChip).approve(address(router), type(uint256).max);
    }

    function _token(uint8 index) internal view returns (Ticket memory) {
        return ticketsOf(hook, roundId)[index];
    }

    /// @dev The fill fee a commit of the current round must carry.
    function _fillFee() internal view returns (uint256) {
        return hook.getConfig(roundId).params.fillFee;
    }

    function _commitBuy(address user, uint8 index, uint256 shares, uint256 limit)
        internal
        returns (uint256 id)
    {
        uint256 fee = _fillFee();
        vm.prank(user);
        id = router.commit{value: fee}(roundId, index, true, shares, limit);
    }

    function _commitSell(address user, uint8 index, uint256 shares, uint256 limit)
        internal
        returns (uint256 id)
    {
        Ticket memory token = _token(index);
        uint256 fee = _fillFee();
        vm.startPrank(user);
        token.approve(address(router), shares);
        id = router.commit{value: fee}(roundId, index, false, shares, limit);
        vm.stopPrank();
    }

    /// @dev Warps to the commit's fill instant and returns the print for it.
    function _printFor(uint256 id, uint256 price) internal returns (bytes memory) {
        uint64 t = router.getCommit(id).fillTs;
        if (clock < t) _warp(t);
        return _print(t, price);
    }

    /// @dev Fills a commit as the keeper at the print for its fill instant, priced at `price`.
    function _fill(uint256 id, uint256 price) internal returns (bool filled) {
        bytes memory report = _printFor(id, price);
        vm.prank(keeper);
        filled = router.fill(id, report);
    }

    /// @dev Commit and fill a buy with the whole balance as the limit. Returns the chips paid.
    function _buy(address user, uint8 index, uint256 shares, uint256 price) internal returns (uint256 cost) {
        uint256 before = MockChip(roundChip).balanceOf(user);
        uint256 id = _commitBuy(user, index, shares, before);
        require(_fill(id, price), "buy refunded");
        cost = before - MockChip(roundChip).balanceOf(user);
    }

    /// @dev Commit and fill a sell with no minimum. Returns the chips received.
    function _sell(address user, uint8 index, uint256 shares, uint256 price)
        internal
        returns (uint256 proceeds)
    {
        uint256 before = MockChip(roundChip).balanceOf(user);
        uint256 id = _commitSell(user, index, shares, 0);
        require(_fill(id, price), "sell refunded");
        proceeds = MockChip(roundChip).balanceOf(user) - before;
    }

    /// @dev Records the close of the current ticker on `day` from the given source.
    function _recordClose(uint256 price, uint8 source) internal {
        uint64 closeAt = NYTime.closeTs(day);
        if (clock < closeAt + 5) _warp(closeAt + 5);
        book.recordClose(
            ticker,
            day,
            source == PYTH_SOURCE ? _pythPrint(ticker, price, closeAt) : _keeperPrint(ticker, price, closeAt)
        );
    }

    /// @dev Trustless close, settle and finalize.
    function _closeAndFinalize(uint256 price) internal {
        _recordClose(price, PYTH_SOURCE);
        hook.settleRound(house, day);
        hook.finalizeRound(house, day);
    }

    /// @dev A fill that must revert (not refund): the commit stays pending. Returns the selector of the
    ///      error (errors come up raw, with no wrap).
    function _fillReverts(uint256 id, bytes memory report) internal returns (bytes4 selector) {
        vm.prank(keeper);
        try router.fill(id, report) returns (bool) {
            revert("fill did not revert");
        } catch (bytes memory err) {
            selector = bytes4(err);
        }
        assertEq(
            uint8(router.getCommit(id).status), uint8(IFallpitRouter.CommitStatus.Pending), "still pending"
        );
    }

    function _state() internal view returns (IFallpitHook.RoundState memory) {
        return hook.getState(roundId);
    }

    // ------------------------------------------------------------------------------------- assertions

    function _assertHookSolvent(address chip_) internal view {
        (uint256 claims, uint256 owed) = Accounting.read(address(hook), chip_);
        assertGe(claims, owed, "the hook's chips cover what it owes");
    }

    function _assertSupplies() internal view {
        (uint256[12] memory supply,) = hook.getSupplies(roundId);
        Ticket[12] memory tokens = ticketsOf(hook, roundId);
        uint256 n = PitMath.count(hook.getConfig(roundId).params.menu);
        for (uint256 i; i < MAX_PRODUCTS; ++i) {
            if (i < n) {
                assertEq(tokens[i].totalSupply(), supply[i], "totalSupply equals outstanding");
            } else {
                assertEq(tokens[i].id, 0, "no token above the menu");
                assertEq(supply[i], 0, "no supply above the menu");
            }
        }
    }

    /// @dev The vault's books for a chip never exceed its balance.
    function _assertVaultBacked(address chip_) internal view {
        assertLe(
            vault.accounted(chip_), MockChip(chip_).balanceOf(address(vault)), "vault books exceed balance"
        );
    }

    /// @dev The risk budget the fixture's rounds open with (bps of capital at g = 1).
    function _testRiskCapBps() internal pure virtual returns (uint16) {
        return 10_000;
    }
}
