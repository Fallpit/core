// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Accounting} from "../Accounting.sol";
import {Ticket, ticketsOf, ticketOf} from "../Ticket.sol";

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

import {FallpitHook} from "../../src/FallpitHook.sol";
import {FallpitRouter} from "../../src/FallpitRouter.sol";
import {PitBook} from "../../src/hook/PitBook.sol";
import {IPitBook} from "../../src/hook/IPitBook.sol";
import {FallpitLens} from "../../src/hook/FallpitLens.sol";
import {IFallpitHook, RefundReason} from "../../src/interfaces/IFallpitHook.sol";
import {IFallpitRouter} from "../../src/interfaces/IFallpitRouter.sol";
import {NYTime} from "../../src/lib/NYTime.sol";
import {ILadderMath} from "../../src/interfaces/ILadderMath.sol";
import {PitMath} from "../../src/hook/PitMath.sol";

import {MockChip} from "./mocks/MockChips.sol";
import {MockLadderMath} from "./mocks/MockLadderMath.sol";
import {MockPitOracle} from "./mocks/MockPitOracle.sol";
import {MockPitVault} from "./mocks/MockPitVault.sol";
import {MockChipGuard} from "./mocks/MockChipGuard.sol";
import {StandardMenu} from "../Menus.sol";

/// @notice Shared setup: a local PoolManager (the router's ETH swaps), the hook, the router, the book and
///         mocks of the math, oracle, vault and chip guard. One NVDA house in an 18-decimal chip is funded
///         and Monday's close is recorded, so Tuesday's round can open. Rounds open with the book's
///         default menu (`StandardMenu` has its product indices) unless a test sets another.
abstract contract HookFixture is Test, StandardMenu {
    bytes32 internal constant NVDA = bytes32("NVDA");
    /// @dev Where the hook is put (any address works).
    address internal constant HOOK_ADDRESS = address(uint160(0xFA11) << 144 | 0x2AA8);
    uint8 internal constant TRUSTLESS = 1;
    uint8 internal constant KEEPER = 2;

    uint256 internal constant S0 = 180e18;
    uint256 internal constant SEED_VAR = 0.0004e18; // sigma = 2%
    uint256 internal constant HOUSE_CAPITAL = 1_000_000e18;
    /// @dev The book's default fill fee: what every commit carries unless a test sets other parameters.
    uint256 internal constant FILL_FEE = 0.0001 ether;

    PoolManager internal pm;
    FallpitRouter internal router;
    FallpitHook internal hook;
    PitBook internal book;
    FallpitLens internal lens;
    MockLadderMath internal math;
    MockPitOracle internal oracle;
    MockPitVault internal vault;
    MockChipGuard internal guard;
    MockChip internal chip;

    address internal owner = makeAddr("owner");
    address internal guardian = makeAddr("guardian");
    address internal feeRecipient = makeAddr("feeRecipient");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal keeper = makeAddr("keeper");

    /// @dev Monday 2026-10-05 and Tuesday 2026-10-06.
    uint32 internal day0;
    uint32 internal day;
    bytes32 internal house;
    bytes32 internal roundId;
    /// @dev Absolute clock; tests never use `block.timestamp + x` (unreliable under via-IR).
    uint64 internal clock;
    mapping(uint64 ts => bytes report) internal _reports;

    function setUp() public virtual {
        day0 = uint32(NYTime.daysFromCivil(2026, 10, 5));
        day = day0 + 1;

        pm = new PoolManager(address(this));
        router = new FallpitRouter(IPoolManager(address(pm)));
        math = new MockLadderMath();
        oracle = new MockPitOracle();
        vault = new MockPitVault();
        guard = new MockChipGuard();
        book = new PitBook(oracle, owner, 24 hours);
        hook = _deployHook(HOOK_ADDRESS, address(router));
        router.setHook(address(hook));
        book.setHook(address(hook));
        vault.setHook(address(hook));
        lens = new FallpitLens(hook, ILadderMath(_mathAddress()));
        chip = new MockChip(18);

        oracle.setSupported(NVDA, true);
        vm.startPrank(owner);
        book.registerTicker(
            NVDA,
            SEED_VAR,
            IPitBook.Clock.NYWeekdays,
            IPitBook.Weights(0, 0, 0, 0),
            0,
            IPitBook.FillSource.KeeperOnly
        );
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

        _warp(NYTime.closeTs(day0) + 60);
        book.recordClose(NVDA, day0, oracle.post(NVDA, TRUSTLESS, S0, NYTime.closeTs(day0)));
        house = _fundHouse(address(chip), HOUSE_CAPITAL);
    }

    /// @dev The pricing engine the hook is wired to; a test may override it with a hostile one.
    function _mathAddress() internal virtual returns (address) {
        return address(math);
    }

    function _deployHook(address at, address router_) internal returns (FallpitHook) {
        deployCodeTo(
            "FallpitHook.sol:FallpitHook",
            abi.encode(
                router_, _mathAddress(), address(oracle), address(vault), address(guard), address(book)
            ),
            at
        );
        return FallpitHook(payable(at));
    }

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

    /// @dev A reseed of a registered ticker, in force now: announced by the owner 24 hours ago.
    function _reseed(
        bytes32 ticker,
        uint256 varWad,
        IPitBook.Clock kind,
        IPitBook.Weights memory weights,
        uint8 windows,
        IPitBook.FillSource source
    ) internal {
        vm.warp(clock - 24 hours);
        vm.prank(owner);
        book.registerTicker(ticker, varWad, kind, weights, windows, source);
        vm.warp(clock);
    }

    function _fundHouse(address chip_, uint256 amount) internal returns (bytes32 house_) {
        guard.set(chip_, true, false);
        house_ = vault.createHouse(NVDA, chip_);
        MockChip(chip_).mint(address(this), amount);
        MockChip(chip_).approve(address(vault), amount);
        vault.deposit(house_, amount);
    }

    /// @dev Opens Tuesday's round and moves the clock one minute into the session.
    function _open() internal returns (bytes32) {
        roundId = hook.openRound(NVDA, address(chip), day);
        _warp(NYTime.openTs(day) + 60);
        return roundId;
    }

    /// @dev Chips to trade with, and ETH for the fill fees of the commits.
    function _fund(address user, uint256 amount) internal {
        vm.deal(user, 10 ether);
        chip.mint(user, amount);
        vm.prank(user);
        chip.approve(address(router), type(uint256).max);
    }

    /// @dev The ticket of product `index` of the current round.
    function _token(uint8 index) internal view returns (Ticket memory) {
        return ticketOf(hook, roundId, index);
    }

    /// @dev The tickets of a round (id zero above its menu).
    function _tickets(bytes32 roundId_) internal view returns (Ticket[12] memory) {
        return ticketsOf(hook, roundId_);
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
        uint256 fee = _fillFee();
        vm.prank(user);
        id = router.commit{value: fee}(roundId, index, false, shares, limit);
    }

    /// @dev Report of the keeper print at `ts`; posts the print (at `price`) when none exists there yet.
    function _report(uint64 ts, uint256 price) internal returns (bytes memory report) {
        report = _reports[ts];
        if (report.length == 0) {
            report = oracle.post(NVDA, KEEPER, price, ts);
            _reports[ts] = report;
        }
    }

    /// @dev Fills a commit as the keeper at the print for its fill instant, priced at `price`.
    function _fill(uint256 id, uint256 price) internal returns (bool filled) {
        uint64 t = router.getCommit(id).fillTs;
        if (clock < t) _warp(t);
        bytes memory report = _report(t, price);
        vm.prank(keeper);
        filled = router.fill(id, report);
    }

    /// @dev Commit and fill a buy with the whole balance as the limit. Returns the chips paid.
    function _buy(address user, uint8 index, uint256 shares, uint256 price) internal returns (uint256 cost) {
        uint256 before = chip.balanceOf(user);
        uint256 id = _commitBuy(user, index, shares, before);
        require(_fill(id, price), "buy refunded");
        cost = before - chip.balanceOf(user);
    }

    /// @dev Commit and fill a sell with no minimum. Returns the chips received.
    function _sell(address user, uint8 index, uint256 shares, uint256 price)
        internal
        returns (uint256 proceeds)
    {
        uint256 before = chip.balanceOf(user);
        uint256 id = _commitSell(user, index, shares, 0);
        require(_fill(id, price), "sell refunded");
        proceeds = chip.balanceOf(user) - before;
    }

    function _recordClose(uint256 price, uint8 source) internal {
        uint64 closeAt = NYTime.closeTs(day);
        if (clock < closeAt + 5) _warp(closeAt + 5);
        book.recordClose(NVDA, day, oracle.post(NVDA, source, price, closeAt));
    }

    /// @dev Trustless close, settle and finalize.
    function _closeAndFinalize(uint256 price) internal {
        _recordClose(price, TRUSTLESS);
        hook.settleRound(house, day);
        hook.finalizeRound(house, day);
    }

    function _state() internal view returns (IFallpitHook.RoundState memory) {
        return hook.getState(roundId);
    }

    function _assertHookSolvent(address chip_) internal view {
        (uint256 claims, uint256 owed) = Accounting.read(address(hook), chip_);
        assertGe(claims, owed, "the hook's chips cover what it owes");
    }

    function _assertSupplies() internal view {
        (uint256[12] memory supply,) = hook.getSupplies(roundId);
        Ticket[12] memory tokens = _tickets(roundId);
        uint256 n = PitMath.count(hook.getConfig(roundId).params.menu);
        for (uint256 i; i < MAX_PRODUCTS; ++i) {
            if (i < n) {
                assertEq(tokens[i].totalSupply(), supply[i], "totalSupply equals outstanding");
            } else {
                assertEq(tokens[i].id, 0, "no ticket above the menu");
                assertEq(supply[i], 0, "no supply above the menu");
            }
        }
    }

    /// @dev The ticket of product `product` of the round (house, day), opened or not.
    function _predictToken(bytes32 house_, uint32 day_, uint8 product) internal view returns (Ticket memory) {
        return ticketOf(hook, hook.roundIdOf(house_, day_), product);
    }

    /// @dev The risk budget the fixture's rounds open with (bps of capital at g = 1).
    function _testRiskCapBps() internal pure virtual returns (uint16) {
        return 10_000;
    }
}
