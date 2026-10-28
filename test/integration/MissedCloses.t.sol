// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console} from "forge-std/Test.sol";
import {PitOracle} from "../../src/PitOracle.sol";
import {IPitBook} from "../../src/hook/IPitBook.sol";
import {IFallpitHook} from "../../src/interfaces/IFallpitHook.sol";
import {NYTime} from "../../src/lib/NYTime.sol";
import {OracleTestBase} from "../oracle/OracleTestBase.sol";
import {MockPyth} from "../oracle/mocks/MockPyth.sol";
import {MockChainlinkFeed} from "../oracle/mocks/MockChainlinkFeed.sol";
import {MockStockToken} from "../oracle/mocks/MockStockToken.sol";
import {StackFixture} from "./StackFixture.sol";

/// @notice A close is verified with the ticker's own `closeMaxLag` (default 300 s, 60 to 900), so the first
///         keeper print after a short outage at the bell is the close. Fills keep the 30 s rule. Real
///         PitOracle.
contract MissedClosesOracleTest is OracleTestBase {
    /// @dev Friday 2026-10-02 16:00:00 New York.
    uint64 internal constant CLOSE = 1790971200;
    int256 internal constant ANSWER = 370.448e8;
    uint256 internal constant PRICE = 370.5e18;

    PitOracle internal oracle;
    address internal owner = makeAddr("owner");

    function setUp() public {
        vm.warp(CLOSE - 3600);
        MockPyth pyth = new MockPyth();
        MockChainlinkFeed feed = new MockChainlinkFeed(8);
        MockStockToken token = new MockStockToken(1e18);
        feed.push(ANSWER, CLOSE - 600);
        _makeSigners(3);
        oracle = new PitOracle(pyth, owner, signerAddrs, 2, 24 hours);
        PitOracle.TickerConfig memory c;
        c.aggregator = address(feed);
        c.stockToken = address(token);
        vm.prank(owner);
        oracle.setTicker(TSLA, c);
    }

    function test_keeperDownAtTheBell_theFirstPrintAfterTheOutageIsTheClose() public {
        assertEq(oracle.config(TSLA).closeMaxLag, 300, "the default close lag");
        uint64 lastTs = CLOSE - 20;
        uint64 backTs = CLOSE + 45;
        vm.warp(backTs + 1);
        PitOracle.Print memory bridge =
            PitOracle.Print({ticker: TSLA, price: PRICE, ts: backTs, prevTs: lastTs});
        bytes memory report = _report2(oracle, bridge, 0, 1);

        // The close: the first print at or after 16:00:00, 45 s late, inside the 300 s of a close.
        (uint256 p, uint64 ts,) = oracle.verifyCloseAt(TSLA, CLOSE, report);
        assertEq(p, PRICE);
        assertEq(ts, backTs);
        // As a fill print for 16:00:00 it is still too late (fills keep the 30 s rule).
        vm.expectRevert(abi.encodeWithSelector(PitOracle.NotThePrintForT.selector, CLOSE, lastTs, backTs));
        oracle.verifyAt(TSLA, CLOSE, report);

        // The edge: 300 s late is a close, 301 s is not.
        vm.warp(CLOSE + 400);
        PitOracle.Print memory edge =
            PitOracle.Print({ticker: TSLA, price: PRICE, ts: CLOSE + 300, prevTs: lastTs});
        (p,,) = oracle.verifyCloseAt(TSLA, CLOSE, _report2(oracle, edge, 0, 1));
        assertEq(p, PRICE);
        PitOracle.Print memory late =
            PitOracle.Print({ticker: TSLA, price: PRICE, ts: CLOSE + 301, prevTs: lastTs});
        bytes memory lateReport = _report2(oracle, late, 0, 1);
        vm.expectRevert(
            abi.encodeWithSelector(PitOracle.NotThePrintForT.selector, CLOSE, lastTs, CLOSE + 301)
        );
        oracle.verifyCloseAt(TSLA, CLOSE, lateReport);
        console.log("outage until 16:00:45: the close is the print covering 15:59:40 to 16:00:45");
    }

    function test_closeMaxLag_boundedSixtyToNineHundred() public {
        PitOracle.TickerConfig memory c = oracle.config(TSLA);
        vm.startPrank(owner);
        c.closeMaxLag = 59;
        vm.expectRevert(PitOracle.InvalidConfig.selector);
        oracle.setTicker(TSLA, c);
        c.closeMaxLag = 901;
        vm.expectRevert(PitOracle.InvalidConfig.selector);
        oracle.setTicker(TSLA, c);
        // a change of a configured ticker is in force SIGNER_DELAY later
        c.closeMaxLag = 900;
        oracle.setTicker(TSLA, c);
        (, uint64 from) = oracle.pendingConfig(TSLA);
        vm.warp(from);
        assertEq(oracle.config(TSLA).closeMaxLag, 900);
        c.closeMaxLag = 60;
        oracle.setTicker(TSLA, c);
        (, from) = oracle.pendingConfig(TSLA);
        vm.warp(from);
        assertEq(oracle.config(TSLA).closeMaxLag, 60);
        vm.stopPrank();
    }
}

/// @notice A close not recorded 12 hours after its instant is missed: from then on the book lets the next
///         round open from the close before (two trading days of variance), and that opening voids the open
///         round of the missed day. One round is lost, refunded at cost, not two. The real hook, router, book
///         and vault.
contract MissedClosesSystemTest is StackFixture {
    address internal lp = makeAddr("lp");
    address internal alice = makeAddr("alice");

    function test_missedClose_costsOneRoundNotTwo() public {
        _lpDeposit(lp, 1_000_000e18);
        _fund(alice, 10_000e18);

        uint32 tuesday = day; // day0 + 1
        uint32 wednesday = tuesday + 1;
        uint32 thursday = tuesday + 2;
        bytes32 tuesdayRound = _open(3600);
        uint256 higher = _token(HIGHER).id;
        uint256 cost = _buy(alice, HIGHER, 100e18, S0 * 1005 / 1000);

        // 16:00:00 Tuesday: no print for more than 300 s at the bell. No close for Tuesday, ever.
        // Up to 04:00:00 Wednesday nothing opens: Tuesday's close may still come.
        _warp(NYTime.closeTs(tuesday) + 12 hours);
        vm.expectRevert(IPitBook.NotNextTradingDay.selector);
        hook.openRound(NVDA, address(chip), wednesday);

        // 04:00:01: Tuesday's close is missed. Wednesday's round opens from Monday's close, on two days
        // of variance, and Tuesday's round is voided in the same call.
        _warp(NYTime.closeTs(tuesday) + 12 hours + 1);
        day = wednesday;
        roundId = hook.openRound(NVDA, address(chip), wednesday);
        assertEq(uint8(hook.getState(tuesdayRound).status), uint8(IFallpitHook.Status.Void), "Tuesday voided");
        IFallpitHook.RoundConfig memory c = hook.getConfig(roundId);
        assertEq(c.s0, S0, "from Monday's close");
        assertEq(c.clock.prevDay, day0);
        assertApproxEqAbs(c.sigma, 0.0282842712474619e18, 1e3, "2% * sqrt(2)");
        assertEq(c.capital, 1_000_000e18, "the house is whole: alice's cost goes back to her");
        vm.prank(alice);
        assertEq(router.redeem(higher, 100e18), cost, "Tuesday's position refunded at cost");

        // Wednesday trades, closes and Thursday opens as usual.
        _warp(NYTime.openTs(wednesday) + 60);
        _buy(alice, HIGHER, 100e18, S0);
        _recordCloseOf(wednesday, S0 * 101 / 100, KEEPER);
        // the variance steps on Monday to Wednesday as two trading days
        int256 ret = 0.00995033085316809e18; // ln(1.01)
        uint256 expected = (94 * SEED_VAR + 6 * (uint256(ret * ret) / 1e18 / 2)) / 100;
        assertApproxEqAbs(book.getTicker(NVDA).varWad, expected, 1e12);
        hook.settleRound(house, wednesday);
        _warp(clock + 900);
        hook.finalizeRound(house, wednesday);
        day = thursday;
        roundId = hook.openRound(NVDA, address(chip), thursday);
        assertEq(uint8(hook.getState(roundId).status), uint8(IFallpitHook.Status.Open));
        console.log("Tuesday's round: Void (refunded at cost); Wednesday: traded and settled; Thursday: open");
    }

    /// @dev Anyone may void a round 24 hours after its close; the earlier void happens only through the
    ///      next round's opening, and never while the close can still come.
    function test_missedClose_voidRoundStillWaits24h() public {
        _lpDeposit(lp, 1_000_000e18);
        _open(3600);
        _warp(NYTime.closeTs(day) + 12 hours + 1);
        vm.expectRevert(IFallpitHook.VoidNotAllowed.selector);
        hook.voidRound(house, day);
        _warp(NYTime.closeTs(day) + 24 hours + 1);
        hook.voidRound(house, day);
        assertEq(uint8(_state().status), uint8(IFallpitHook.Status.Void));
    }
}
