// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {DeployTestnet} from "../../script/DeployTestnet.s.sol";
import {PitOracle} from "../../src/PitOracle.sol";
import {MirrorFeed, MirrorStockToken} from "../../src/testnet/MirrorFeed.sol";
import {OracleTestBase} from "../oracle/OracleTestBase.sol";
import {MockPyth} from "../oracle/mocks/MockPyth.sol";

/// @notice On testnet a keeper print is bounded by the ticker's MirrorFeed, and the mirror pusher can move
///         that reference to any price, also for past instants (a round may be dated anywhere between the
///         previous round and now). A print the oracle refused a minute ago verifies after one push, and one
///         that verified is refused after another: on testnet the bound is only as good as the pusher (SPEC
///         9).
contract MirrorPusherTest is OracleTestBase {
    uint64 internal constant T0 = 1791000000;
    PitOracle internal oracle;
    MirrorFeed internal feed;
    address internal owner = makeAddr("owner");
    address internal pusher = makeAddr("pusher");

    function setUp() public {
        vm.warp(T0);
        MockPyth pyth = new MockPyth();
        feed = new MirrorFeed(8, "NVDA / USD (mirror of 4663)", owner, pusher);
        MirrorStockToken token = new MirrorStockToken(feed, 1e18);
        vm.prank(pusher);
        feed.push(180e8, T0 - 300);
        _makeSigners(3);
        oracle = new PitOracle(pyth, owner, signerAddrs, 2, 24 hours);
        PitOracle.TickerConfig memory c;
        c.aggregator = address(feed);
        c.stockToken = address(token);
        vm.prank(owner);
        oracle.setTicker(TSLA, c);
    }

    function test_mirrorPusher_decidesTheBoundRetroactively_onTestnetOnly() public {
        // A print 5% above the reference: refused, as it should be.
        uint64 ts = T0 + 60;
        vm.warp(ts + 1);
        PitOracle.Print memory p = PitOracle.Print({ticker: TSLA, price: 189e18, ts: ts, prevTs: ts - 1});
        bytes memory report = _report2(oracle, p, 0, 1);
        vm.expectRevert(abi.encodeWithSelector(PitOracle.OutOfBound.selector, 189e18, 180e18));
        oracle.verifyAt(TSLA, ts, report);

        // The pusher pushes a round dated BEFORE the print (allowed: not before the previous round, not in
        // the future). The same print now verifies: the round "in force at ts" is the pushed one.
        vm.prank(pusher);
        feed.push(189e8, ts - 10);
        (uint256 price,,) = oracle.verifyAt(TSLA, ts, report);
        assertEq(price, 189e18);

        // And the other way round: a print that verified is refused after the next push. A print at
        // ts2 inside the band of the current round...
        uint64 ts2 = ts + 120;
        vm.warp(ts2 + 1);
        PitOracle.Print memory q = PitOracle.Print({ticker: TSLA, price: 189.5e18, ts: ts2, prevTs: ts2 - 1});
        bytes memory report2 = _report2(oracle, q, 0, 1);
        (price,,) = oracle.verifyAt(TSLA, ts2, report2);
        assertEq(price, 189.5e18);
        // ...is refused once the pusher dates a far round just before it (a fill in flight reverts).
        vm.prank(pusher);
        feed.push(170e8, ts2 - 1);
        vm.expectRevert(abi.encodeWithSelector(PitOracle.OutOfBound.selector, 189.5e18, 170e18));
        oracle.verifyAt(TSLA, ts2, report2);
        console.log(
            "the MirrorFeed pusher moves the reference for past instants: the bound is the pusher's choice"
        );
    }
}

/// @notice The testnet deploy script refuses a mirror pusher that is also a keeper signer.
contract DeployRefusesSignerPusherTest is Test {
    function test_deployRefusesAMirrorPusherThatSigns() public {
        vm.warp(1_791_000_000);
        PoolManager pm = new PoolManager(address(this));
        MockPyth pyth = new MockPyth();
        DeployTestnet script = new DeployTestnet();
        DeployTestnet.Config memory cfg;
        cfg.poolManager = address(pm);
        cfg.pyth = address(pyth);
        cfg.owner = makeAddr("owner");
        cfg.guardian = makeAddr("guardian");
        cfg.feeRecipient = makeAddr("fees");
        cfg.signers = new address[](3);
        cfg.signers[0] = address(0x1001);
        cfg.signers[1] = address(0x1002);
        cfg.signers[2] = address(0x1003);
        cfg.threshold = 2;
        cfg.mirrorPusher = address(0x1002); // the pusher is signer 2
        cfg.tickers = new DeployTestnet.TickerSetup[](1);
        cfg.tickers[0] = script.tickerSetup("NVDA");
        cfg.chipNames = new string[](1);
        cfg.chipNames[0] = "Pit Rat";
        cfg.chipSymbols = new string[](1);
        cfg.chipSymbols[0] = "RAT";
        cfg.chipSupply = 1_000_000e18;
        vm.expectRevert(abi.encodeWithSelector(DeployTestnet.MirrorPusherIsSigner.selector, address(0x1002)));
        script.deployAll(cfg);
        // another key: deployed
        cfg.mirrorPusher = address(0x2001);
        DeployTestnet.System memory s = script.deployAll(cfg);
        assertEq(s.feeds[0].pusher(), address(0x2001));
    }
}
