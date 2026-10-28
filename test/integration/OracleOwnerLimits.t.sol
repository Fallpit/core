// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

import {FallpitHook} from "../../src/FallpitHook.sol";
import {FallpitRouter} from "../../src/FallpitRouter.sol";
import {Ticket, ticketsOf, ticketOf} from "../Ticket.sol";
import {StandardMenu} from "../Menus.sol";
import {LadderMath} from "../../src/LadderMath.sol";
import {PitVault} from "../../src/PitVault.sol";
import {PitOracle} from "../../src/PitOracle.sol";
import {PitBook} from "../../src/hook/PitBook.sol";
import {IPitBook} from "../../src/hook/IPitBook.sol";
import {IFallpitHook} from "../../src/interfaces/IFallpitHook.sol";
import {IChipGuard} from "../../src/interfaces/IChipGuard.sol";
import {IPitOracle} from "../../src/interfaces/IPitOracle.sol";
import {ITickerGate} from "../../src/interfaces/IPitVault.sol";
import {NYTime} from "../../src/lib/NYTime.sol";

import {MockChip} from "../hook/mocks/MockChips.sol";
import {MockChipGuard} from "../hook/mocks/MockChipGuard.sol";
import {MockPyth} from "../oracle/mocks/MockPyth.sol";

/// @notice The oracle owner cannot reprice an open round. A ticker's Pyth feed cannot be re-pointed or
///         removed while it is pinned, a signer set or threshold change takes effect 24 hours after it is
///         announced, a keeper print needs a configured aggregator, and a round is priced by exactly one
///         source. The real PitOracle (with a stand-in for the Pyth core contract), FallpitHook,
///         FallpitRouter, PitBook, LadderMath and PitVault.
contract OracleOwnerLimitsTest is Test, StandardMenu {
    bytes32 internal constant NVDA = bytes32("NVDA");
    bytes32 internal constant NVDA_FEED = bytes32(uint256(0xfeed));
    address internal constant HOOK_ADDRESS = address((uint160(0xFA11) << 144) | 0x2AA8);
    int64 internal constant PYTH_S0 = 180e5; // 180.00000 with expo -5
    uint256 internal constant S0 = 180e18;
    uint256 internal constant CAPITAL = 1_000_000e18;
    uint256 internal constant LOT = 20_000e18;
    /// @dev The book's default fill fee: what every commit carries.
    uint256 internal constant FILL_FEE = 0.0001 ether;

    PoolManager internal pm;
    FallpitRouter internal router;
    FallpitHook internal hook;
    PitBook internal book;
    PitOracle internal oracle;
    MockPyth internal pyth;
    PitVault internal vault;
    MockChipGuard internal guard;
    MockChip internal chip;

    address internal bookOwner = makeAddr("bookOwner");
    address internal oracleOwner = makeAddr("oracleOwner");
    address internal lp = makeAddr("lp");
    address internal eve;
    uint256 internal eveKey;

    uint32 internal day0;
    uint32 internal day;
    bytes32 internal house;
    bytes32 internal roundId;

    function setUp() public {
        (eve, eveKey) = makeAddrAndKey("eve");
        day0 = uint32(NYTime.daysFromCivil(2026, 10, 5));
        day = day0 + 1;

        pm = new PoolManager(address(this));
        router = new FallpitRouter(IPoolManager(address(pm)));
        pyth = new MockPyth();
        oracle = new PitOracle(pyth, oracleOwner, new address[](0), 0, 24 hours);
        guard = new MockChipGuard();
        book = new PitBook(IPitOracle(address(oracle)), bookOwner, 24 hours);
        vault = new PitVault(HOOK_ADDRESS, IChipGuard(address(guard)), ITickerGate(address(book)));
        vault.setLister(address(this));
        deployCodeTo(
            "FallpitHook.sol:FallpitHook",
            abi.encode(
                address(router),
                address(new LadderMath()),
                address(oracle),
                address(vault),
                address(guard),
                address(book)
            ),
            HOOK_ADDRESS
        );
        hook = FallpitHook(payable(HOOK_ADDRESS));
        router.setHook(address(hook));
        book.setHook(address(hook));
        chip = new MockChip(18);

        // NVDA is set up as a Pyth-only ticker: a feed id, no Chainlink aggregator, no signers at all.
        PitOracle.TickerConfig memory cfg;
        cfg.pythFeedId = NVDA_FEED;
        vm.prank(oracleOwner);
        oracle.setTicker(NVDA, cfg);
        vm.prank(bookOwner);
        book.registerTicker(
            NVDA,
            0.0004e18,
            IPitBook.Clock.NYWeekdays,
            IPitBook.Weights(0, 0, 0, 0),
            0,
            IPitBook.FillSource.TrustlessOnly
        );

        // Monday's close from Pyth, an honest house, Tuesday's round.
        uint64 close0 = NYTime.closeTs(day0);
        vm.warp(close0 + 60);
        book.recordClose(NVDA, day0, _pythReport(PYTH_S0, close0));
        guard.set(address(chip), true, false);
        house = vault.createHouse(NVDA, address(chip));
        chip.mint(lp, CAPITAL);
        vm.startPrank(lp);
        chip.approve(address(vault), CAPITAL);
        vault.deposit(house, CAPITAL);
        vm.stopPrank();
        roundId = hook.openRound(NVDA, address(chip), day);
    }

    function _pythReport(int64 price, uint64 ts) internal view returns (bytes memory) {
        return abi.encodePacked(uint8(0x01), pyth.encode(NVDA_FEED, price, 100, -5, ts, ts - 1));
    }

    function _keeperReport(uint256 price, uint64 ts) internal view returns (bytes memory) {
        PitOracle.Print memory p = PitOracle.Print({ticker: NVDA, price: price, ts: ts, prevTs: ts - 1});
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(eveKey, oracle.printDigest(p));
        bytes[] memory sigs = new bytes[](1);
        sigs[0] = abi.encodePacked(r, s, v);
        return abi.encodePacked(uint8(0x02), abi.encode(p, sigs));
    }

    function test_oracleOwner_cannotMispriceAnOpenRound() public {
        uint64 now_ = NYTime.openTs(day) + 3600;
        vm.warp(now_);
        chip.mint(eve, 100_000e18);
        vm.prank(eve);
        chip.approve(address(router), type(uint256).max);
        IFallpitHook.RoundConfig memory frozen = hook.getConfig(roundId);
        assertEq(uint8(frozen.fillSource), uint8(IPitBook.FillSource.TrustlessOnly));

        // The owner's transaction, mid-round: eve is to be the whole signer set. It is only announced.
        address[] memory signers = new address[](1);
        signers[0] = eve;
        vm.prank(oracleOwner);
        oracle.setSigners(signers, 1);
        assertEq(oracle.threshold(), 0, "not in force");
        assertFalse(oracle.isSigner(eve));
        (address[] memory waiting,, uint64 activeFrom) = oracle.pendingSigners();
        assertEq(waiting.length, 1);
        assertEq(activeFrom, now_ + 24 hours, "in the open, a day ahead");

        // Eve tries the trade: LOWER at a keeper print of 360 while the stock trades at 180.
        uint256 start = chip.balanceOf(eve);
        vm.deal(eve, 1 ether);
        vm.prank(eve);
        uint256 id = router.commit{value: FILL_FEE}(roundId, LOWER, true, LOT, LOT);
        now_ += 2;
        vm.warp(now_);
        bytes memory forged = _keeperReport(2 * S0, now_);
        vm.prank(eve);
        vm.expectRevert(); // no keeper source: SourceNotConfigured
        router.fill(id, forged);
        assertEq(ticketsOf(hook, roundId)[LOWER].totalSupply(), 0, "nothing was minted");

        // Re-pointing the ticker's Pyth feed at another asset is refused outright ...
        PitOracle.TickerConfig memory cfg;
        cfg.pythFeedId = bytes32(uint256(0xbad));
        vm.prank(oracleOwner);
        vm.expectRevert(PitOracle.SourcePinned.selector);
        oracle.setTicker(NVDA, cfg);
        // ... and so is removing it.
        cfg.pythFeedId = bytes32(0);
        vm.prank(oracleOwner);
        vm.expectRevert(PitOracle.SourcePinned.selector);
        oracle.setTicker(NVDA, cfg);

        // The honest Pyth print still fills the commit, at the real price.
        vm.prank(eve);
        assertTrue(router.fill(id, _pythReport(PYTH_S0, now_)));
        uint256 fair = start - chip.balanceOf(eve);
        assertGt(
            fair,
            9_000e18,
            "20,000 LOWER at the money cost about half a chip each, not 507 chips for ten lots"
        );

        // A day later the announced signer set is in force. The ticker still has no aggregator, so it
        // still has no keeper source: eve's print verifies nowhere.
        vm.warp(now_ + 24 hours);
        assertEq(oracle.threshold(), 1);
        vm.expectRevert(abi.encodeWithSelector(PitOracle.SourceNotConfigured.selector, NVDA, uint8(2)));
        oracle.verifyAt(NVDA, now_, forged);
        // The round's own config never changed.
        assertEq(keccak256(abi.encode(hook.getConfig(roundId))), keccak256(abi.encode(frozen)));
    }

    /// @dev A ticker configured with a Pyth feed and nothing else has no keeper source: a keeper print
    ///      at ten times the Pyth price is refused, whatever the signer set.
    function test_keeperPrint_refusedOnATickerWithoutChainlinkFeed() public {
        uint64 t = NYTime.openTs(day) + 100;
        vm.warp(t);
        // an oracle whose signer set is eve from the start, so nothing is waiting on a delay
        address[] memory signers = new address[](1);
        signers[0] = eve;
        PitOracle live = new PitOracle(pyth, oracleOwner, signers, 1, 24 hours);
        PitOracle.TickerConfig memory cfg;
        cfg.pythFeedId = NVDA_FEED;
        vm.prank(oracleOwner);
        live.setTicker(NVDA, cfg);
        assertEq(live.threshold(), 1);

        (uint256 pythPrice,, bool trustless) = live.verifyAt(NVDA, t, _pythReport(PYTH_S0, t));
        assertEq(pythPrice, S0);
        assertTrue(trustless);

        PitOracle.Print memory p = PitOracle.Print({ticker: NVDA, price: 10 * S0, ts: t, prevTs: t - 1});
        (uint8 v, bytes32 r, bytes32 s_) = vm.sign(eveKey, live.printDigest(p));
        bytes[] memory sigs = new bytes[](1);
        sigs[0] = abi.encodePacked(r, s_, v);
        bytes memory report = abi.encodePacked(uint8(0x02), abi.encode(p, sigs));
        vm.expectRevert(abi.encodeWithSelector(PitOracle.SourceNotConfigured.selector, NVDA, uint8(2)));
        live.verifyAt(NVDA, t, report);
        // at the Pyth price itself it is refused just the same: there is nothing to bound it with
        p.price = S0;
        (v, r, s_) = vm.sign(eveKey, live.printDigest(p));
        sigs[0] = abi.encodePacked(r, s_, v);
        report = abi.encodePacked(uint8(0x02), abi.encode(p, sigs));
        vm.expectRevert(abi.encodeWithSelector(PitOracle.SourceNotConfigured.selector, NVDA, uint8(2)));
        live.verifyAt(NVDA, t, report);
    }

    /// @dev A Pyth print of a 16:00:00 four months ago still verifies in the real PitOracle (the oracle
    ///      checks a print against its own instant, never against the current time). The book does not
    ///      take it from just anyone, and never books the gap to yesterday's close as one daily return.
    function test_recordClose_refusesAMonthsOldPrint_andNeverBooksTheGapAsOneReturn() public {
        bytes32 gme = bytes32("GME");
        bytes32 gmeFeed = bytes32(uint256(0x6de));
        PitOracle.TickerConfig memory cfg;
        cfg.pythFeedId = gmeFeed;
        vm.prank(oracleOwner);
        oracle.setTicker(gme, cfg);
        // registered a day ago (a new ticker is in force 24 hours after its registration)
        uint64 nowTs = NYTime.closeTs(day0) + 60;
        vm.warp(nowTs - 24 hours);
        vm.prank(bookOwner);
        book.registerTicker(
            gme,
            0.0004e18,
            IPitBook.Clock.NYWeekdays,
            IPitBook.Weights(0, 0, 0, 0),
            0,
            IPitBook.FillSource.TrustlessOnly
        );
        vm.warp(nowTs);

        uint32 june1 = uint32(NYTime.daysFromCivil(2026, 6, 1));
        uint64 oldClose = NYTime.closeTs(june1);
        uint64 close0 = NYTime.closeTs(day0);
        assertGt(close0 - oldClose, 120 days);
        bytes memory oldReport =
            abi.encodePacked(uint8(0x01), pyth.encode(gmeFeed, 20e5, 100, -5, oldClose, oldClose - 1));
        bytes memory newReport =
            abi.encodePacked(uint8(0x01), pyth.encode(gmeFeed, 27e5, 100, -5, close0, close0 - 1));
        // the oracle itself has no notion of "old"
        (uint256 oldPrice,,) = oracle.verifyAt(gme, oldClose, oldReport);
        assertEq(oldPrice, 20e18);

        vm.startPrank(eve);
        vm.expectRevert(IPitBook.CloseTooOld.selector);
        book.recordClose(gme, june1, oldReport);
        book.recordClose(gme, day0, newReport);
        vm.stopPrank();
        assertEq(book.getTicker(gme).varWad, 0.0004e18, "the first close is no return");

        // seeded by the owner in date order instead, the 30% gap is still not one daily return
        bytes32 amc = bytes32("AMC");
        cfg.pythFeedId = bytes32(uint256(0xa3c));
        vm.prank(oracleOwner);
        oracle.setTicker(amc, cfg);
        vm.warp(nowTs - 24 hours);
        vm.startPrank(bookOwner);
        book.registerTicker(
            amc,
            0.0004e18,
            IPitBook.Clock.NYWeekdays,
            IPitBook.Weights(0, 0, 0, 0),
            0,
            IPitBook.FillSource.TrustlessOnly
        );
        vm.warp(nowTs);
        book.recordClose(
            amc,
            june1,
            abi.encodePacked(uint8(0x01), pyth.encode(cfg.pythFeedId, 20e5, 100, -5, oldClose, oldClose - 1))
        );
        vm.stopPrank();
        vm.prank(eve);
        book.recordClose(
            amc,
            day0,
            abi.encodePacked(uint8(0x01), pyth.encode(cfg.pythFeedId, 27e5, 100, -5, close0, close0 - 1))
        );
        uint256 varWad = book.getTicker(amc).varWad;
        console.log("daily variance: seeded 400000000000000, now %s (WAD)", varWad);
        assertEq(varWad, 0.0004e18, "unchanged");
    }
}
