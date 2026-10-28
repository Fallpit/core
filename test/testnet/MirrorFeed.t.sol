// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PitOracle} from "../../src/PitOracle.sol";
import {MirrorFeed, MirrorStockToken} from "../../src/testnet/MirrorFeed.sol";
import {OracleTestBase} from "../oracle/OracleTestBase.sol";
import {MockPyth} from "../oracle/mocks/MockPyth.sol";

contract MirrorFeedTest is OracleTestBase {
    /// @dev Friday 2026-10-02 16:00:00 New York and the TSLA round in force then (15:55:31, 370.448).
    uint64 internal constant T = 1790971200;
    uint64 internal constant ROUND_TS = 1790970931;
    uint80 internal constant PHASE = uint80(1) << 64;

    MirrorFeed internal feed;
    MirrorStockToken internal token;
    PitOracle internal oracle;
    address internal owner = makeAddr("owner");
    address internal pusher = makeAddr("pusher");

    function setUp() public {
        vm.warp(T + 5);
        feed = new MirrorFeed(8, "TSLA / USD (mirror of 4663)", owner, pusher);
        token = new MirrorStockToken(feed, 1e18);
        _makeSigners(3);
        oracle = new PitOracle(new MockPyth(), owner, signerAddrs, 2, 24 hours);
    }

    function test_constructor() public {
        assertEq(feed.decimals(), 8);
        assertEq(feed.description(), "TSLA / USD (mirror of 4663)");
        assertEq(feed.owner(), owner);
        assertEq(feed.pusher(), pusher);
        assertEq(feed.version(), 1);
        assertEq(feed.roundCount(), 0);
        vm.expectRevert(MirrorFeed.ZeroAddress.selector);
        new MirrorFeed(8, "x", address(0), pusher);
        vm.expectRevert(MirrorFeed.ZeroAddress.selector);
        new MirrorFeed(8, "x", owner, address(0));
        vm.expectRevert(MirrorFeed.BadDecimals.selector);
        new MirrorFeed(19, "x", owner, pusher);
        vm.expectRevert(MirrorStockToken.BadMultiplier.selector);
        new MirrorStockToken(feed, 0);
    }

    function test_emptyFeed_readsAsZeros_likeTheRealProxy() public view {
        (uint80 id, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredIn) =
            feed.latestRoundData();
        assertEq(id, PHASE);
        assertEq(answer, 0);
        assertEq(startedAt, 0);
        assertEq(updatedAt, 0);
        assertEq(answeredIn, PHASE);
        (, answer,, updatedAt,) = feed.getRoundData(PHASE | 7);
        assertEq(answer, 0);
        assertEq(updatedAt, 0);
    }

    function test_push_onlyThePusher_appendOnly_timesNeverGoBack() public {
        vm.expectRevert(MirrorFeed.OnlyPusher.selector);
        feed.push(370.448e8, ROUND_TS);
        vm.prank(owner);
        vm.expectRevert(MirrorFeed.OnlyPusher.selector);
        feed.push(370.448e8, ROUND_TS);

        vm.startPrank(pusher);
        vm.expectEmit(true, false, false, true);
        emit MirrorFeed.RoundPushed(PHASE | 1, 372.495e8, ROUND_TS - 60);
        assertEq(feed.push(372.495e8, ROUND_TS - 60), PHASE | 1);
        assertEq(feed.push(370.448e8, ROUND_TS), PHASE | 2);
        // same time again is fine (two mainnet rounds in one second), earlier is not
        assertEq(feed.push(370.5e8, ROUND_TS), PHASE | 3);
        vm.expectRevert(MirrorFeed.BadTime.selector);
        feed.push(370.5e8, ROUND_TS - 1);
        // not from the future, not zero, not a non-positive answer
        vm.expectRevert(MirrorFeed.BadTime.selector);
        feed.push(370.5e8, T + 6);
        vm.expectRevert(MirrorFeed.BadAnswer.selector);
        feed.push(0, T);
        vm.expectRevert(MirrorFeed.BadAnswer.selector);
        feed.push(-1, T);
        vm.stopPrank();
        MirrorFeed fresh = new MirrorFeed(8, "x", owner, pusher);
        vm.prank(pusher);
        vm.expectRevert(MirrorFeed.BadTime.selector);
        fresh.push(1, 0);

        assertEq(feed.roundCount(), 3);
        (uint80 id, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredIn) =
            feed.latestRoundData();
        assertEq(id, PHASE | 3);
        assertEq(answer, 370.5e8);
        assertEq(startedAt, ROUND_TS);
        assertEq(updatedAt, ROUND_TS);
        assertEq(answeredIn, PHASE | 3);
        (, answer,, updatedAt,) = feed.getRoundData(PHASE | 1);
        assertEq(answer, 372.495e8);
        assertEq(updatedAt, ROUND_TS - 60);
        // a round of another phase, round 0 and a round past the end read as zeros
        (, answer,, updatedAt,) = feed.getRoundData(1);
        assertEq(updatedAt, 0);
        (, answer,, updatedAt,) = feed.getRoundData(PHASE);
        assertEq(updatedAt, 0);
        (, answer,, updatedAt,) = feed.getRoundData(PHASE | 4);
        assertEq(updatedAt, 0);
    }

    function test_setPusher_onlyOwner() public {
        address next = makeAddr("next");
        vm.expectRevert(MirrorFeed.OnlyOwner.selector);
        feed.setPusher(next);
        vm.prank(pusher);
        vm.expectRevert(MirrorFeed.OnlyOwner.selector);
        feed.setPusher(next);
        vm.startPrank(owner);
        vm.expectRevert(MirrorFeed.ZeroAddress.selector);
        feed.setPusher(address(0));
        feed.setPusher(next);
        vm.stopPrank();
        vm.prank(pusher);
        vm.expectRevert(MirrorFeed.OnlyPusher.selector);
        feed.push(1e8, T);
        vm.prank(next);
        feed.push(1e8, T);
        // the stock token stub follows the feed's pusher
        vm.prank(pusher);
        vm.expectRevert(MirrorStockToken.OnlyPusher.selector);
        token.setMultiplier(2e18);
        vm.prank(next);
        token.setMultiplier(2e18);
        assertEq(token.uiMultiplier(), 2e18);
        vm.prank(next);
        vm.expectRevert(MirrorStockToken.BadMultiplier.selector);
        token.setMultiplier(0);
    }

    /// @dev The point of the mirror: PitOracle bounds keeper prints on testnet exactly as on mainnet,
    ///      including the multiplier, the round in force at the print, and the walk back from the latest.
    function test_pitOracle_boundsKeeperPrintsWithTheMirror() public {
        bytes32 ticker = TSLA;
        PitOracle.TickerConfig memory c;
        c.aggregator = address(feed);
        c.stockToken = address(token);
        vm.prank(owner);
        oracle.setTicker(ticker, c);

        PitOracle.Print memory p =
            PitOracle.Print({ticker: ticker, price: 370.65425e18, ts: T, prevTs: T - 1});
        // nothing mirrored yet: the print cannot be bounded
        bytes memory report = _report2(oracle, p, 0, 1);
        vm.expectRevert(PitOracle.ChainlinkRoundNotFound.selector);
        oracle.verifyAt(ticker, T, report);

        vm.startPrank(pusher);
        feed.push(372.495e8, ROUND_TS - 60);
        feed.push(370.448e8, ROUND_TS);
        vm.stopPrank();
        (uint256 price,, bool trustless) = oracle.verifyAt(ticker, T, report);
        assertEq(price, 370.65425e18);
        assertFalse(trustless);

        // 76 bps above the round in force: refused
        p.price = uint256(370.448e18) * 10_076 / 10_000;
        report = _report2(oracle, p, 0, 1);
        vm.expectRevert(abi.encodeWithSelector(PitOracle.OutOfBound.selector, p.price, 370.448e18));
        oracle.verifyAt(ticker, T, report);

        // a post-market round mirrored later does not bound the 16:00 print
        vm.warp(T + 4000);
        vm.prank(pusher);
        feed.push(380e8, T + 3500);
        p.price = 370.65425e18;
        oracle.verifyAt(ticker, T, _report2(oracle, p, 0, 1));

        // a 4-for-1 style multiplier: the feed prices the token, the print prices the stock
        vm.prank(pusher);
        token.setMultiplier(4e18);
        report = _report2(oracle, p, 0, 1);
        vm.expectRevert(abi.encodeWithSelector(PitOracle.OutOfBound.selector, p.price, 92.612e18));
        oracle.verifyAt(ticker, T, report);
        p.price = 92.7e18;
        (price,,) = oracle.verifyAt(ticker, T, _report2(oracle, p, 0, 1));
        assertEq(price, 92.7e18);
    }
}
