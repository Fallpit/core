// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

import {FallpitHook} from "../../src/FallpitHook.sol";
import {FallpitRouter} from "../../src/FallpitRouter.sol";
import {Ticket, ticketsOf, ticketOf} from "../Ticket.sol";
import {LadderMath} from "../../src/LadderMath.sol";
import {PitVault} from "../../src/PitVault.sol";
import {PitBook} from "../../src/hook/PitBook.sol";
import {IPitBook} from "../../src/hook/IPitBook.sol";
import {FallpitLens} from "../../src/hook/FallpitLens.sol";
import {IFallpitHook} from "../../src/interfaces/IFallpitHook.sol";
import {IChipGuard} from "../../src/interfaces/IChipGuard.sol";
import {IPitOracle} from "../../src/interfaces/IPitOracle.sol";
import {ITickerGate} from "../../src/interfaces/IPitVault.sol";
import {ILadderMath} from "../../src/interfaces/ILadderMath.sol";
import {NYTime} from "../../src/lib/NYTime.sol";

import {MockChip} from "../hook/mocks/MockChips.sol";
import {MockChipGuard} from "../hook/mocks/MockChipGuard.sol";
import {TickOracle} from "./mocks/TickOracle.sol";
import {StandardMenu} from "../Menus.sol";

/// @notice The real FallpitHook, FallpitRouter, PitBook, LadderMath and PitVault, with a
///         local PoolManager for the router. Only the oracle (a one-print-per-second feed) and the chip guard
///         are stand-ins.
abstract contract StackFixture is Test, StandardMenu {
    bytes32 internal constant NVDA = bytes32("NVDA");
    uint160 internal constant HOOK_FLAGS = 0x2AA8;
    address internal constant HOOK_ADDRESS = address((uint160(0xFA11) << 144) | HOOK_FLAGS);
    uint8 internal constant TRUSTLESS = 1;
    uint8 internal constant KEEPER = 2;

    uint256 internal constant S0 = 180e18;
    uint256 internal constant SEED_VAR = 0.0004e18; // sigma = 2%
    /// @dev The book's default fill fee: what every commit carries.
    uint256 internal constant FILL_FEE = 0.0001 ether;

    PoolManager internal pm;
    FallpitRouter internal router;
    FallpitHook internal hook;
    PitBook internal book;
    FallpitLens internal lens;
    LadderMath internal math;
    TickOracle internal oracle;
    PitVault internal vault;
    MockChipGuard internal guard;
    MockChip internal chip;

    address internal owner = makeAddr("owner");
    address internal guardian = makeAddr("guardian");
    address internal feeRecipient = makeAddr("feeRecipient");
    address internal keeper = makeAddr("keeper");

    uint32 internal day0;
    uint32 internal day;
    bytes32 internal house;
    bytes32 internal roundId;
    /// @dev Ticker whose prints `_fillAt` posts (the ticker of `roundId`).
    bytes32 internal activeTicker = NVDA;
    /// @dev Absolute clock; tests never use `block.timestamp + x` (unreliable under via-IR).
    uint64 internal clock;

    function setUp() public virtual {
        day0 = uint32(NYTime.daysFromCivil(2026, 10, 5)); // Monday
        day = day0 + 1;

        pm = new PoolManager(address(this));
        router = new FallpitRouter(IPoolManager(address(pm)));
        math = new LadderMath();
        oracle = new TickOracle();
        guard = new MockChipGuard();
        book = new PitBook(IPitOracle(address(oracle)), owner, 24 hours);
        // the book gates houses, as deployed
        vault = new PitVault(HOOK_ADDRESS, IChipGuard(address(guard)), ITickerGate(address(book)));
        vault.setLister(address(this));
        deployCodeTo(
            "FallpitHook.sol:FallpitHook",
            abi.encode(
                address(router), address(math), address(oracle), address(vault), address(guard), address(book)
            ),
            HOOK_ADDRESS
        );
        hook = FallpitHook(payable(HOOK_ADDRESS));
        router.setHook(address(hook));
        book.setHook(address(hook));
        lens = new FallpitLens(hook, ILadderMath(address(math)));
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
        // as in the other fixtures: the first per-fill cap (2%) and the risk budget out of the way
        IPitBook.Params memory p = book.defaultParams();
        (p.riskCapBps, p.maxFillBps) = (10_000, 200);
        book.setDefaultParams(p);
        vm.stopPrank();

        _warp(NYTime.closeTs(day0) + 60);
        _recordCloseOf(day0, S0, TRUSTLESS);

        guard.set(address(chip), true, false);
        house = vault.createHouse(NVDA, address(chip));
    }

    function _warp(uint64 to) internal {
        require(to >= clock, "clock goes forward");
        clock = to;
        vm.warp(to);
    }

    /// @dev Another menu for the rounds opened from now on (the owner announced it 24 hours ago).
    function _setMenu(uint256 menu) internal {
        IPitBook.Params memory p = book.defaultParams();
        p.menu = menu;
        vm.warp(clock - 24 hours);
        vm.prank(owner);
        book.setDefaultParams(p);
        vm.warp(clock);
    }

    function _recordCloseOf(uint32 d, uint256 price, uint8 source) internal {
        uint64 closeAt = NYTime.closeTs(d);
        if (clock < closeAt + 5) _warp(closeAt + 5);
        oracle.set(NVDA, source, closeAt, price);
        book.recordClose(NVDA, d, abi.encode(source));
    }

    function _lpDeposit(address lp, uint256 amount) internal {
        chip.mint(lp, amount);
        vm.startPrank(lp);
        chip.approve(address(vault), amount);
        vault.deposit(house, amount);
        vm.stopPrank();
    }

    function _donate(address from, uint256 amount) internal {
        chip.mint(from, amount);
        vm.startPrank(from);
        chip.approve(address(vault), amount);
        vault.donate(house, amount);
        vm.stopPrank();
    }

    /// @dev Opens the round of `day` and moves the clock `into` seconds into the session.
    function _open(uint64 into) internal returns (bytes32) {
        roundId = hook.openRound(NVDA, address(chip), day);
        _warp(NYTime.openTs(day) + into);
        return roundId;
    }

    /// @dev Chips to trade with, and ETH for the fill fees of the commits.
    function _fund(address user, uint256 amount) internal {
        vm.deal(user, 10 ether);
        chip.mint(user, amount);
        vm.prank(user);
        chip.approve(address(router), type(uint256).max);
    }

    function _token(uint8 index) internal view returns (Ticket memory) {
        return ticketsOf(hook, roundId)[index];
    }

    /// @dev Commit now and fill at the keeper print for the commit's instant, priced at `price`.
    ///      `filled` is false when the fill was refunded.
    function _tryBuy(address user, uint8 index, uint256 shares, uint256 price)
        internal
        returns (bool filled, uint256 cost)
    {
        uint256 before = chip.balanceOf(user);
        vm.prank(user);
        uint256 id = router.commit{value: FILL_FEE}(roundId, index, true, shares, before);
        filled = _fillAt(id, price);
        cost = before - chip.balanceOf(user);
    }

    function _buy(address user, uint8 index, uint256 shares, uint256 price) internal returns (uint256 cost) {
        bool filled;
        (filled, cost) = _tryBuy(user, index, shares, price);
        require(filled, "buy refunded");
    }

    function _trySell(address user, uint8 index, uint256 shares, uint256 price)
        internal
        returns (bool filled, uint256 proceeds)
    {
        uint256 before = chip.balanceOf(user);
        Ticket memory token = _token(index);
        vm.startPrank(user);
        token.approve(address(router), shares);
        uint256 id = router.commit{value: FILL_FEE}(roundId, index, false, shares, 0);
        vm.stopPrank();
        filled = _fillAt(id, price);
        proceeds = chip.balanceOf(user) - before;
    }

    function _sell(address user, uint8 index, uint256 shares, uint256 price)
        internal
        returns (uint256 proceeds)
    {
        bool filled;
        (filled, proceeds) = _trySell(user, index, shares, price);
        require(filled, "sell refunded");
    }

    function _fillAt(uint256 id, uint256 price) internal returns (bool filled) {
        uint64 t = router.getCommit(id).fillTs;
        if (clock < t) _warp(t);
        if (oracle.priceAt(activeTicker, KEEPER, t) == 0) oracle.set(activeTicker, KEEPER, t, price);
        vm.prank(keeper);
        filled = router.fill(id, abi.encode(KEEPER));
    }

    function _closeAndFinalize(uint256 price) internal {
        _recordCloseOf(day, price, TRUSTLESS);
        hook.settleRound(house, day);
        hook.finalizeRound(house, day);
    }

    function _state() internal view returns (IFallpitHook.RoundState memory) {
        return hook.getState(roundId);
    }

    /// @dev S0 * exp(k * sigma) for sigma = 2%, with k in WAD (1e18 = one daily standard deviation).
    function _priceAtSigmas(int256 kWad) internal pure returns (uint256) {
        return S0 * uint256(FixedPointMathLib.expWad(kWad * 2 / 100)) / 1e18;
    }
}
