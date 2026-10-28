// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "solady/auth/Ownable.sol";
import {PitOracle} from "../../src/PitOracle.sol";
import {IPitOracle} from "../../src/interfaces/IPitOracle.sol";
import {IPyth} from "../../src/oracle/IPyth.sol";
import {OracleTestBase} from "./OracleTestBase.sol";
import {MockPyth} from "./mocks/MockPyth.sol";
import {MockChainlinkFeed} from "./mocks/MockChainlinkFeed.sol";
import {MockStockToken} from "./mocks/MockStockToken.sol";

/// @dev Calls the oracle with value and cannot receive the refund.
contract RefundRejecter {
    function call(IPitOracle oracle, bytes32 ticker, uint64 t, bytes calldata report) external payable {
        oracle.verifyAt{value: msg.value}(ticker, t, report);
    }
}

contract PitOracleTest is OracleTestBase {
    bytes32 internal constant PYTH_ONLY = bytes32("PYTHONLY");
    bytes32 internal constant KEEPER_ONLY = bytes32("KEEPERONLY");
    bytes32 internal constant TSLA_ID = 0x16dad506d7db8da01c87581c87ca897a012a153557d4d578c3b9c9e1bc0632f1;
    bytes32 internal constant OTHER_ID = bytes32(uint256(0xbeef));

    /// @dev Friday 2026-10-02 16:00:00 New York.
    uint64 internal constant T = 1790971200;
    /// @dev The TSLA push feed round in force at that close (15:55:31, 370.448).
    uint256 internal constant ROUND_TS = 1790970931;
    int256 internal constant ROUND_ANSWER = 370.448e8;
    uint256 internal constant REF = 370.448e18;
    uint256 internal constant PRICE = 370.65425e18;
    /// @dev The clock after `setUp`. Tests warp to absolute times: `block.timestamp + x` after a warp is
    ///      unreliable under via-IR.
    uint64 internal constant NOW = T + 5;

    PitOracle internal oracle;
    MockPyth internal pyth;
    MockChainlinkFeed internal feed;
    MockStockToken internal token;
    address internal owner = makeAddr("owner");

    function setUp() public {
        vm.warp(NOW);
        pyth = new MockPyth();
        feed = new MockChainlinkFeed(8);
        token = new MockStockToken(1e18);
        feed.push(372.495e8, ROUND_TS - 60);
        feed.push(ROUND_ANSWER, ROUND_TS);
        // The first signer set comes with the constructor; every later change waits 24 hours.
        _makeSigners(3);
        oracle = new PitOracle(pyth, owner, signerAddrs, 2, 24 hours);

        vm.startPrank(owner);
        oracle.setTicker(TSLA, _cfg(TSLA_ID, address(feed), address(token)));
        oracle.setTicker(PYTH_ONLY, _cfg(TSLA_ID, address(0), address(0)));
        oracle.setTicker(KEEPER_ONLY, _cfg(bytes32(0), address(feed), address(token)));
        vm.stopPrank();
    }

    receive() external payable {}

    function _cfg(bytes32 id, address aggregator, address stockToken)
        internal
        pure
        returns (PitOracle.TickerConfig memory c)
    {
        c.pythFeedId = id;
        c.aggregator = aggregator;
        c.stockToken = stockToken;
    }

    function _print(uint256 price) internal pure returns (PitOracle.Print memory) {
        return PitOracle.Print({ticker: TSLA, price: price, ts: T, prevTs: T - 1});
    }

    function _blob(int64 price, uint64 conf, int32 expo, uint64 publishTime, uint64 prev)
        internal
        view
        returns (bytes memory)
    {
        return _pythReport(pyth.encode(TSLA_ID, price, conf, expo, publishTime, prev));
    }

    // -------------------------------------------------------------------------------------------- Pyth

    function test_pyth_verifiesTheFirstUpdateAtOrAfterT() public {
        (uint256 price, uint64 ts, bool trustless) =
            oracle.verifyAt(TSLA, T, _blob(37065425, 6125, -5, T, T - 1));
        assertEq(price, PRICE);
        assertEq(ts, T);
        assertTrue(trustless);
    }

    function test_pyth_acceptsAnUpdateUpToMaxLagAfterT() public {
        vm.warp(T + 60);
        (uint256 price, uint64 ts,) = oracle.verifyAt(TSLA, T, _blob(37065425, 6125, -5, T + 30, T - 1));
        assertEq(price, PRICE);
        assertEq(ts, T + 30);
    }

    function test_pyth_revertsBeyondMaxLag() public {
        vm.warp(T + 60);
        bytes memory report = _blob(37065425, 6125, -5, T + 31, T - 1);
        vm.expectRevert(IPyth.PriceFeedNotFoundWithinRange.selector);
        oracle.verifyAt(TSLA, T, report);
    }

    function test_pyth_revertsForANonUniqueUpdate() public {
        // An update at T whose predecessor was also at or after T is not the first one after T.
        bytes memory report = _blob(37065425, 6125, -5, T + 1, T);
        vm.expectRevert(IPyth.PriceFeedNotFoundWithinRange.selector);
        oracle.verifyAt(TSLA, T, report);
    }

    function test_pyth_revertsWhenReplayedForADifferentT() public {
        bytes memory report = _blob(37065425, 6125, -5, T, T - 1);
        vm.expectRevert(IPyth.PriceFeedNotFoundWithinRange.selector);
        oracle.verifyAt(TSLA, T - 1, report);
        vm.expectRevert(IPyth.PriceFeedNotFoundWithinRange.selector);
        oracle.verifyAt(TSLA, T + 1, report);
    }

    function test_pyth_revertsForAnotherFeed() public {
        bytes memory report = _pythReport(pyth.encode(OTHER_ID, 37065425, 6125, -5, T, T - 1));
        vm.expectRevert(IPyth.PriceFeedNotFoundWithinRange.selector);
        oracle.verifyAt(TSLA, T, report);
    }

    function test_pyth_revertsWhenTheCoreReturnsAnotherFeed() public {
        pyth.setForcedId(OTHER_ID);
        bytes memory report = _blob(37065425, 6125, -5, T, T - 1);
        vm.expectRevert(abi.encodeWithSelector(PitOracle.WrongFeed.selector, OTHER_ID));
        oracle.verifyAt(TSLA, T, report);
    }

    function test_pyth_revertsOnNonPositivePrice() public {
        bytes memory zero = _blob(0, 0, -5, T, T - 1);
        vm.expectRevert(PitOracle.NonPositivePrice.selector);
        oracle.verifyAt(TSLA, T, zero);
        bytes memory negative = _blob(-1, 0, -5, T, T - 1);
        vm.expectRevert(PitOracle.NonPositivePrice.selector);
        oracle.verifyAt(TSLA, T, negative);
    }

    function test_pyth_confidenceBoundary() public {
        // maxConfBps defaults to 100: conf / price <= 1%.
        (uint256 price,,) = oracle.verifyAt(TSLA, T, _blob(37065400, 370654, -5, T, T - 1));
        assertEq(price, 370.654e18);
        bytes memory wide = _blob(37065400, 370655, -5, T, T - 1);
        vm.expectRevert(abi.encodeWithSelector(PitOracle.ConfidenceTooWide.selector, 370655, 37065400));
        oracle.verifyAt(TSLA, T, wide);
    }

    function test_pyth_convertsExpoToWad() public {
        (uint256 p8,,) = oracle.verifyAt(TSLA, T, _blob(37065425000, 0, -8, T, T - 1));
        assertEq(p8, PRICE);
        (uint256 p18,,) = oracle.verifyAt(TSLA, T, _blob(int64(370.65425e16), 0, -18, T, T - 1));
        assertEq(p18, 370.65425e16);
        (uint256 p0,,) = oracle.verifyAt(TSLA, T, _blob(370, 0, 0, T, T - 1));
        assertEq(p0, 370e18);
    }

    function test_pyth_revertsOnUnsupportedExpo() public {
        bytes memory positive = _blob(37, 0, 1, T, T - 1);
        vm.expectRevert(abi.encodeWithSelector(PitOracle.UnsupportedExpo.selector, int32(1)));
        oracle.verifyAt(TSLA, T, positive);
        bytes memory tiny = _blob(37, 0, -19, T, T - 1);
        vm.expectRevert(abi.encodeWithSelector(PitOracle.UnsupportedExpo.selector, int32(-19)));
        oracle.verifyAt(TSLA, T, tiny);
    }

    function testFuzz_pyth_convertsExpoToWad(int64 price, uint8 negExpo) public {
        price = int64(bound(price, 1, type(int64).max));
        int32 expo = -int32(uint32(bound(negExpo, 0, 18)));
        (uint256 wad,,) = oracle.verifyAt(TSLA, T, _blob(price, 0, expo, T, T - 1));
        assertEq(wad, uint256(uint64(price)) * 10 ** (18 - uint256(uint32(-expo))));
    }

    function test_pyth_paysTheFeeAndRefundsTheRest() public {
        pyth.setFee(7);
        bytes memory report = _blob(37065425, 6125, -5, T, T - 1);
        uint256 before = address(this).balance;
        oracle.verifyAt{value: 1 ether}(TSLA, T, report);
        assertEq(address(pyth).balance, 7);
        assertEq(address(this).balance, before - 7);
        assertEq(address(oracle).balance, 0);
    }

    function test_pyth_revertsOnInsufficientFee() public {
        pyth.setFee(7);
        bytes memory report = _blob(37065425, 6125, -5, T, T - 1);
        vm.expectRevert(abi.encodeWithSelector(PitOracle.InsufficientFee.selector, 7, 6));
        oracle.verifyAt{value: 6}(TSLA, T, report);
    }

    function test_pyth_revertsWhenTheRefundIsRejected() public {
        RefundRejecter rejecter = new RefundRejecter();
        bytes memory report = _blob(37065425, 6125, -5, T, T - 1);
        vm.expectRevert(PitOracle.RefundFailed.selector);
        rejecter.call{value: 1}(oracle, TSLA, T, report);
        // With the exact fee there is nothing to refund.
        pyth.setFee(1);
        rejecter.call{value: 1}(oracle, TSLA, T, report);
    }

    function test_pyth_revertsWhenTheTickerHasNoFeedId() public {
        bytes memory report = _blob(37065425, 6125, -5, T, T - 1);
        vm.expectRevert(abi.encodeWithSelector(PitOracle.SourceNotConfigured.selector, KEEPER_ONLY, uint8(1)));
        oracle.verifyAt(KEEPER_ONLY, T, report);
    }

    // ------------------------------------------------------------------------------------------ keeper

    function test_keeper_verifiesATwoOfThreePrint() public {
        PitOracle.Print memory p = _print(PRICE);
        (uint256 price, uint64 ts, bool trustless) = oracle.verifyAt(TSLA, T, _report2(oracle, p, 0, 2));
        assertEq(price, PRICE);
        assertEq(ts, T);
        assertFalse(trustless);
    }

    function test_keeper_acceptsAllThreeSignatures() public {
        PitOracle.Print memory p = _print(PRICE);
        bytes[] memory sigs = new bytes[](3);
        for (uint256 i; i < 3; ++i) {
            sigs[i] = _sign(oracle, keys[i], p);
        }
        (uint256 price,,) = oracle.verifyAt(TSLA, T, _report(p, sigs));
        assertEq(price, PRICE);
    }

    function test_keeper_revertsBelowThreshold() public {
        PitOracle.Print memory p = _print(PRICE);
        bytes[] memory sigs = new bytes[](1);
        sigs[0] = _sign(oracle, keys[0], p);
        vm.expectRevert(abi.encodeWithSelector(PitOracle.NotEnoughSignatures.selector, 1, 2));
        oracle.verifyAt(TSLA, T, _report(p, sigs));
    }

    function test_keeper_revertsOnTheSameSignerTwice() public {
        PitOracle.Print memory p = _print(PRICE);
        bytes memory report = _report2(oracle, p, 1, 1);
        vm.expectRevert(PitOracle.SignersNotAscending.selector);
        oracle.verifyAt(TSLA, T, report);
    }

    function test_keeper_revertsOnDescendingSigners() public {
        PitOracle.Print memory p = _print(PRICE);
        bytes memory report = _report2(oracle, p, 2, 0);
        vm.expectRevert(PitOracle.SignersNotAscending.selector);
        oracle.verifyAt(TSLA, T, report);
    }

    function test_keeper_revertsOnAnOutsider() public {
        PitOracle.Print memory p = _print(PRICE);
        (address outsider, uint256 outsiderKey) = makeAddrAndKey("outsider");
        bytes[] memory sigs = new bytes[](2);
        // Order the two so that the ascending rule holds and the membership rule is what fails.
        if (outsider < signerAddrs[0]) {
            sigs[0] = _sign(oracle, outsiderKey, p);
            sigs[1] = _sign(oracle, keys[0], p);
        } else {
            sigs[0] = _sign(oracle, keys[0], p);
            sigs[1] = _sign(oracle, outsiderKey, p);
        }
        vm.expectRevert(abi.encodeWithSelector(PitOracle.NotASigner.selector, outsider));
        oracle.verifyAt(TSLA, T, _report(p, sigs));
    }

    function test_keeper_revertsOnTheMalleableTwin() public {
        PitOracle.Print memory p = _print(PRICE);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(keys[0], oracle.printDigest(p));
        // (r, n - s, flipped v) recovers to the same signer under plain ecrecover.
        uint256 n = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
        bytes32 s2 = bytes32(n - uint256(s));
        uint8 v2 = v == 27 ? 28 : 27;
        assertEq(ecrecover(oracle.printDigest(p), v2, r, s2), signerAddrs[0]);

        bytes[] memory sigs = new bytes[](2);
        sigs[0] = abi.encodePacked(r, s2, v2);
        sigs[1] = _sign(oracle, keys[1], p);
        vm.expectRevert(PitOracle.MalleableSignature.selector);
        oracle.verifyAt(TSLA, T, _report(p, sigs));

        // One signer cannot count twice through its twin either.
        sigs[0] = abi.encodePacked(r, s, v);
        sigs[1] = abi.encodePacked(r, s2, v2);
        vm.expectRevert(PitOracle.MalleableSignature.selector);
        oracle.verifyAt(TSLA, T, _report(p, sigs));
    }

    function test_keeper_revertsOnOtherSignatureEncodings() public {
        PitOracle.Print memory p = _print(PRICE);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(keys[0], oracle.printDigest(p));
        bytes[] memory sigs = new bytes[](2);
        sigs[1] = _sign(oracle, keys[1], p);

        // EIP-2098 compact form (64 bytes).
        sigs[0] = abi.encodePacked(r, bytes32(uint256(s) | (uint256(v - 27) << 255)));
        vm.expectRevert(PitOracle.BadSignature.selector);
        oracle.verifyAt(TSLA, T, _report(p, sigs));

        // v as 0 or 1.
        sigs[0] = abi.encodePacked(r, s, v - 27);
        vm.expectRevert(PitOracle.BadSignature.selector);
        oracle.verifyAt(TSLA, T, _report(p, sigs));

        // A signature that recovers to nobody.
        sigs[0] = abi.encodePacked(bytes32(0), bytes32(uint256(1)), uint8(27));
        vm.expectRevert(PitOracle.BadSignature.selector);
        oracle.verifyAt(TSLA, T, _report(p, sigs));
    }

    function test_keeper_revertsOnAnotherChain() public {
        vm.chainId(4663);
        PitOracle.Print memory p = _print(PRICE);
        bytes memory report = _report2(oracle, p, 0, 1);
        (uint256 price,,) = oracle.verifyAt(TSLA, T, report);
        assertEq(price, PRICE);

        // The same signed print on the testnet chain id recovers to strangers.
        vm.chainId(46630);
        vm.expectPartialRevert(PitOracle.NotASigner.selector);
        oracle.verifyAt(TSLA, T, report);
    }

    function test_keeper_revertsOnAnotherDeployment() public {
        PitOracle other = new PitOracle(pyth, owner, signerAddrs, 2, 24 hours);
        vm.prank(owner);
        other.setTicker(TSLA, _cfg(TSLA_ID, address(feed), address(token)));
        PitOracle.Print memory p = _print(PRICE);
        bytes memory report = _report2(oracle, p, 0, 1);
        vm.expectPartialRevert(PitOracle.NotASigner.selector);
        other.verifyAt(TSLA, T, report);
    }

    function test_keeper_revertsWhenReplayedForADifferentT() public {
        PitOracle.Print memory p = _print(PRICE);
        bytes memory report = _report2(oracle, p, 0, 1);
        vm.expectRevert(abi.encodeWithSelector(PitOracle.NotThePrintForT.selector, T - 1, T - 1, T));
        oracle.verifyAt(TSLA, T - 1, report);
        vm.expectRevert(abi.encodeWithSelector(PitOracle.NotThePrintForT.selector, T + 1, T - 1, T));
        oracle.verifyAt(TSLA, T + 1, report);
    }

    function test_keeper_revertsForANonUniquePrint() public {
        // A print after T whose predecessor was also at or after T is not the first one after T.
        vm.warp(T + 10);
        PitOracle.Print memory p = PitOracle.Print({ticker: TSLA, price: PRICE, ts: T + 2, prevTs: T});
        bytes memory report = _report2(oracle, p, 0, 1);
        vm.expectRevert(abi.encodeWithSelector(PitOracle.NotThePrintForT.selector, T, T, T + 2));
        oracle.verifyAt(TSLA, T, report);
        // It is the print for T + 1 and T + 2.
        oracle.verifyAt(TSLA, T + 1, report);
        oracle.verifyAt(TSLA, T + 2, report);
    }

    function test_keeper_maxLagBoundary() public {
        vm.warp(T + 100);
        feed.push(ROUND_ANSWER, T + 20);
        PitOracle.Print memory ok = PitOracle.Print({ticker: TSLA, price: PRICE, ts: T + 30, prevTs: T - 1});
        oracle.verifyAt(TSLA, T, _report2(oracle, ok, 0, 1));
        PitOracle.Print memory late = PitOracle.Print({ticker: TSLA, price: PRICE, ts: T + 31, prevTs: T - 1});
        bytes memory report = _report2(oracle, late, 0, 1);
        vm.expectRevert(abi.encodeWithSelector(PitOracle.NotThePrintForT.selector, T, T - 1, T + 31));
        oracle.verifyAt(TSLA, T, report);
    }

    function test_keeper_revertsOnAnotherTicker() public {
        PitOracle.Print memory p =
            PitOracle.Print({ticker: bytes32("NVDA"), price: PRICE, ts: T, prevTs: T - 1});
        bytes memory report = _report2(oracle, p, 0, 1);
        vm.expectRevert(abi.encodeWithSelector(PitOracle.WrongTicker.selector, bytes32("NVDA")));
        oracle.verifyAt(TSLA, T, report);
    }

    function test_keeper_revertsOnAPrintFromTheFuture() public {
        vm.warp(T - 1);
        PitOracle.Print memory p = _print(PRICE);
        bytes memory report = _report2(oracle, p, 0, 1);
        vm.expectRevert(abi.encodeWithSelector(PitOracle.PrintFromTheFuture.selector, T));
        oracle.verifyAt(TSLA, T, report);
    }

    function test_keeper_revertsOnZeroPrice() public {
        PitOracle.Print memory p = _print(0);
        bytes memory report = _report2(oracle, p, 0, 1);
        vm.expectRevert(PitOracle.NonPositivePrice.selector);
        oracle.verifyAt(TSLA, T, report);
    }

    function test_keeper_revertsWithoutASignerSet() public {
        PitOracle.Print memory p = _print(PRICE);
        bytes memory report = _report2(oracle, p, 0, 1);
        // Removing the signer set is a signer change like any other: it waits 24 hours.
        vm.prank(owner);
        oracle.setSigners(new address[](0), 0);
        oracle.verifyAt(TSLA, T, report);
        vm.warp(NOW + 24 hours);
        vm.expectRevert(abi.encodeWithSelector(PitOracle.SourceNotConfigured.selector, TSLA, uint8(2)));
        oracle.verifyAt(TSLA, T, report);

        // An oracle that never had a signer set has no keeper source at all.
        PitOracle bare = new PitOracle(pyth, owner, new address[](0), 0, 24 hours);
        vm.prank(owner);
        bare.setTicker(TSLA, _cfg(TSLA_ID, address(feed), address(token)));
        report = _report2(bare, p, 0, 1);
        vm.expectRevert(abi.encodeWithSelector(PitOracle.SourceNotConfigured.selector, TSLA, uint8(2)));
        bare.verifyAt(TSLA, T, report);
    }

    function test_keeper_refundsAnyValue() public {
        PitOracle.Print memory p = _print(PRICE);
        bytes memory report = _report2(oracle, p, 0, 1);
        uint256 before = address(this).balance;
        oracle.verifyAt{value: 1 ether}(TSLA, T, report);
        assertEq(address(this).balance, before);
        assertEq(address(oracle).balance, 0);
    }

    // ---------------------------------------------------------------------------------- Chainlink bound

    function test_bound_boundaryAt60Bps() public {
        uint256 up = REF * 10060 / 10000;
        uint256 down = REF * 9940 / 10000;
        oracle.verifyAt(TSLA, T, _report2(oracle, _print(up), 0, 1));
        oracle.verifyAt(TSLA, T, _report2(oracle, _print(down), 0, 1));

        bytes memory tooHigh = _report2(oracle, _print(up + 1), 0, 1);
        vm.expectRevert(abi.encodeWithSelector(PitOracle.OutOfBound.selector, up + 1, REF));
        oracle.verifyAt(TSLA, T, tooHigh);
        bytes memory tooLow = _report2(oracle, _print(down - 1), 0, 1);
        vm.expectRevert(abi.encodeWithSelector(PitOracle.OutOfBound.selector, down - 1, REF));
        oracle.verifyAt(TSLA, T, tooLow);
    }

    function testFuzz_bound_acceptsExactlyWithin60Bps(uint256 price) public {
        price = bound(price, REF * 95 / 100, REF * 105 / 100);
        uint256 diff = price > REF ? price - REF : REF - price;
        bytes memory report = _report2(oracle, _print(price), 0, 1);
        if (diff * 1e4 <= REF * 60) {
            (uint256 got,,) = oracle.verifyAt(TSLA, T, report);
            assertEq(got, price);
        } else {
            vm.expectRevert(abi.encodeWithSelector(PitOracle.OutOfBound.selector, price, REF));
            oracle.verifyAt(TSLA, T, report);
        }
    }

    function test_bound_multiplierOfFour() public {
        // CRWD-style: one token is four shares, so the feed prints four times the stock price.
        MockChainlinkFeed crwdFeed = new MockChainlinkFeed(8);
        MockStockToken crwdToken = new MockStockToken(4e18);
        crwdFeed.push(1092.16e8, ROUND_TS);
        bytes32 crwd = bytes32("CRWD");
        vm.prank(owner);
        oracle.setTicker(crwd, _cfg(bytes32(0), address(crwdFeed), address(crwdToken)));

        PitOracle.Print memory stock = PitOracle.Print({ticker: crwd, price: 273.5e18, ts: T, prevTs: T - 1});
        (uint256 price,,) = oracle.verifyAt(crwd, T, _report2(oracle, stock, 0, 1));
        assertEq(price, 273.5e18);

        // The raw token price is 300% away from the stock price and must not pass.
        PitOracle.Print memory tokenPrice =
            PitOracle.Print({ticker: crwd, price: 1092.16e18, ts: T, prevTs: T - 1});
        bytes memory report = _report2(oracle, tokenPrice, 0, 1);
        vm.expectRevert(abi.encodeWithSelector(PitOracle.OutOfBound.selector, 1092.16e18, 273.04e18));
        oracle.verifyAt(crwd, T, report);
    }

    function test_bound_fractionalMultiplier() public {
        // AAPL-style dividend accrual: multiplier 1.000566080061092436.
        token.setMultiplier(1.000566080061092436e18);
        uint256 ref = uint256(370.448e18) * 1e18 / 1.000566080061092436e18;
        uint256 up = ref * 10060 / 10000;
        oracle.verifyAt(TSLA, T, _report2(oracle, _print(up), 0, 1));
        bytes memory report = _report2(oracle, _print(up + 1), 0, 1);
        vm.expectRevert(abi.encodeWithSelector(PitOracle.OutOfBound.selector, up + 1, ref));
        oracle.verifyAt(TSLA, T, report);
    }

    function test_bound_feedWithoutAStockTokenUsesMultiplierOne() public {
        bytes32 raw = bytes32("RAW");
        vm.prank(owner);
        oracle.setTicker(raw, _cfg(bytes32(0), address(feed), address(0)));
        PitOracle.Print memory p = PitOracle.Print({ticker: raw, price: PRICE, ts: T, prevTs: T - 1});
        (uint256 price,,) = oracle.verifyAt(raw, T, _report2(oracle, p, 0, 1));
        assertEq(price, PRICE);
    }

    function test_bound_feedWith18Decimals() public {
        MockChainlinkFeed wadFeed = new MockChainlinkFeed(18);
        wadFeed.push(370.448e18, ROUND_TS);
        bytes32 t18 = bytes32("WAD");
        vm.prank(owner);
        oracle.setTicker(t18, _cfg(bytes32(0), address(wadFeed), address(0)));
        PitOracle.Print memory p = PitOracle.Print({ticker: t18, price: PRICE, ts: T, prevTs: T - 1});
        oracle.verifyAt(t18, T, _report2(oracle, p, 0, 1));
    }

    function test_bound_staleFeedStillBoundsADriftedPrice() public {
        // The NVDA case of 2026-10-02: the last round is almost three hours old at the close. A price that
        // drifted 0.4% since then passes; one that is 0.8% away does not, however honest it may be.
        MockChainlinkFeed nvda = new MockChainlinkFeed(8);
        nvda.push(234.99712e8, T - 2 hours - 52 minutes);
        bytes32 ticker = bytes32("NVDA");
        vm.prank(owner);
        oracle.setTicker(ticker, _cfg(bytes32(0), address(nvda), address(0)));

        uint256 ref = 234.99712e18;
        PitOracle.Print memory near =
            PitOracle.Print({ticker: ticker, price: ref * 1004 / 1000, ts: T, prevTs: T - 1});
        oracle.verifyAt(ticker, T, _report2(oracle, near, 0, 1));

        PitOracle.Print memory far =
            PitOracle.Print({ticker: ticker, price: ref * 1008 / 1000, ts: T, prevTs: T - 1});
        bytes memory report = _report2(oracle, far, 0, 1);
        vm.expectRevert(abi.encodeWithSelector(PitOracle.OutOfBound.selector, ref * 1008 / 1000, ref));
        oracle.verifyAt(ticker, T, report);
    }

    function test_bound_revertsWhenTheFeedIsTooOld() public {
        // maxFeedAge defaults to 5 days: a feed that stopped updating bounds nothing.
        MockChainlinkFeed dead = new MockChainlinkFeed(8);
        dead.push(ROUND_ANSWER, T - 5 days - 1);
        bytes32 ticker = bytes32("DEAD");
        vm.prank(owner);
        oracle.setTicker(ticker, _cfg(bytes32(0), address(dead), address(0)));
        PitOracle.Print memory p = PitOracle.Print({ticker: ticker, price: PRICE, ts: T, prevTs: T - 1});
        bytes memory report = _report2(oracle, p, 0, 1);
        vm.expectRevert(abi.encodeWithSelector(PitOracle.ChainlinkStale.selector, T - 5 days - 1, T));
        oracle.verifyAt(ticker, T, report);

        // Exactly at the limit it still counts. (A second ticker: a ticker's feed can be set only once.)
        MockChainlinkFeed old = new MockChainlinkFeed(8);
        old.push(ROUND_ANSWER, T - 5 days);
        p.ticker = bytes32("OLD");
        vm.prank(owner);
        oracle.setTicker(p.ticker, _cfg(bytes32(0), address(old), address(0)));
        oracle.verifyAt(p.ticker, T, _report2(oracle, p, 0, 1));
    }

    function test_bound_usesTheRoundInForceAtThePrintNotTheLatest() public {
        // After the close the feed moves 2% in the post market (GME did on 2026-10-02). The 16:00 print is
        // posted an hour later and still verifies; a print near the post-market price does not.
        feed.push(ROUND_ANSWER * 101 / 100, T + 58 minutes);
        feed.push(ROUND_ANSWER * 102 / 100, T + 115 minutes);
        vm.warp(T + 2 hours);
        (uint256 price,,) = oracle.verifyAt(TSLA, T, _report2(oracle, _print(PRICE), 0, 1));
        assertEq(price, PRICE);

        uint256 postMarket = REF * 102 / 100;
        bytes memory report = _report2(oracle, _print(postMarket), 0, 1);
        vm.expectRevert(abi.encodeWithSelector(PitOracle.OutOfBound.selector, postMarket, REF));
        oracle.verifyAt(TSLA, T, report);
    }

    function test_bound_aRoundWithinTheGraceAfterThePrintCounts() public {
        // The price jumps 1% at T and the push feed reports it 60 s later: the print leads the feed.
        uint256 jumped = REF * 101 / 100;
        bytes memory report = _report2(oracle, _print(jumped), 0, 1);
        vm.expectRevert(abi.encodeWithSelector(PitOracle.OutOfBound.selector, jumped, REF));
        oracle.verifyAt(TSLA, T, report);

        feed.push(ROUND_ANSWER * 101 / 100, T + 60);
        vm.warp(T + 61);
        (uint256 price,,) = oracle.verifyAt(TSLA, T, report);
        assertEq(price, jumped);
        // The round in force at T still counts as well.
        oracle.verifyAt(TSLA, T, _report2(oracle, _print(PRICE), 0, 1));
    }

    function test_bound_aRoundAfterTheGraceDoesNotCount() public {
        uint256 jumped = REF * 101 / 100;
        feed.push(ROUND_ANSWER * 101 / 100, T + 61);
        vm.warp(T + 62);
        bytes memory report = _report2(oracle, _print(jumped), 0, 1);
        vm.expectRevert(abi.encodeWithSelector(PitOracle.OutOfBound.selector, jumped, REF));
        oracle.verifyAt(TSLA, T, report);
    }

    function test_bound_revertsWhenTheWalkIsTooLong() public {
        // 64 rounds after the print can be walked, 65 cannot.
        for (uint256 i; i < 64; ++i) {
            feed.push(ROUND_ANSWER, T + 100 + i);
        }
        vm.warp(T + 1 days);
        bytes memory report = _report2(oracle, _print(PRICE), 0, 1);
        oracle.verifyAt(TSLA, T, report);
        feed.push(ROUND_ANSWER, T + 200);
        vm.expectRevert(PitOracle.ChainlinkRoundNotFound.selector);
        oracle.verifyAt(TSLA, T, report);
    }

    function test_bound_revertsWhenNoRoundIsOldEnough() public {
        MockChainlinkFeed young = new MockChainlinkFeed(8);
        young.push(ROUND_ANSWER, T + 61);
        bytes32 ticker = bytes32("YOUNG");
        vm.prank(owner);
        oracle.setTicker(ticker, _cfg(bytes32(0), address(young), address(0)));
        vm.warp(T + 100);
        PitOracle.Print memory p = PitOracle.Print({ticker: ticker, price: PRICE, ts: T, prevTs: T - 1});
        bytes memory report = _report2(oracle, p, 0, 1);
        vm.expectRevert(PitOracle.ChainlinkRoundNotFound.selector);
        oracle.verifyAt(ticker, T, report);

        // (A second ticker: a ticker's feed can be set only once.)
        MockChainlinkFeed empty = new MockChainlinkFeed(8);
        p.ticker = bytes32("EMPTY");
        vm.prank(owner);
        oracle.setTicker(p.ticker, _cfg(bytes32(0), address(empty), address(0)));
        report = _report2(oracle, p, 0, 1);
        vm.expectRevert(PitOracle.ChainlinkRoundNotFound.selector);
        oracle.verifyAt(p.ticker, T, report);
    }

    function test_bound_revertsOnANonPositiveAnswer() public {
        feed.push(0, T - 10);
        bytes memory report = _report2(oracle, _print(PRICE), 0, 1);
        vm.expectRevert(PitOracle.ChainlinkBadAnswer.selector);
        oracle.verifyAt(TSLA, T, report);
    }

    function test_bound_revertsOnAZeroMultiplier() public {
        token.setMultiplier(0);
        bytes memory report = _report2(oracle, _print(PRICE), 0, 1);
        vm.expectRevert(PitOracle.ChainlinkBadAnswer.selector);
        oracle.verifyAt(TSLA, T, report);
    }

    /// @dev A keeper print must always be bounded, so a ticker without a push feed has no keeper source
    ///      and a keeper print for it does not verify at any price.
    function test_keeper_revertsWhenTheTickerHasNoFeed() public {
        PitOracle.Print memory p = PitOracle.Print({ticker: PYTH_ONLY, price: 1e18, ts: T, prevTs: T - 1});
        bytes memory report = _report2(oracle, p, 0, 1);
        vm.expectRevert(abi.encodeWithSelector(PitOracle.SourceNotConfigured.selector, PYTH_ONLY, uint8(2)));
        oracle.verifyAt(PYTH_ONLY, T, report);
        // Even a print at the Pyth price itself: without a feed there is nothing to bound it with.
        p.price = PRICE;
        report = _report2(oracle, p, 0, 1);
        vm.expectRevert(abi.encodeWithSelector(PitOracle.SourceNotConfigured.selector, PYTH_ONLY, uint8(2)));
        oracle.verifyAt(PYTH_ONLY, T, report);
    }

    function testFuzz_keeper_acceptsOnlyThePrintForT(uint64 t, uint64 prevTs, uint64 ts) public {
        vm.warp(T + 1000);
        t = uint64(bound(t, T - 100, T + 100));
        prevTs = uint64(bound(prevTs, T - 200, T + 200));
        ts = uint64(bound(ts, T - 200, T + 200));
        // KEEPER_ONLY has the push feed (a keeper print needs one); its round at ROUND_TS is in force for
        // every ts drawn here and PRICE is inside its bound, so only the instant rule decides.
        PitOracle.Print memory p =
            PitOracle.Print({ticker: KEEPER_ONLY, price: PRICE, ts: ts, prevTs: prevTs});
        bytes memory report = _report2(oracle, p, 0, 1);
        if (prevTs < t && t <= ts && ts <= t + 30) {
            (uint256 price, uint64 gotTs,) = oracle.verifyAt(KEEPER_ONLY, t, report);
            assertEq(price, PRICE);
            assertEq(gotTs, ts);
        } else {
            vm.expectRevert(abi.encodeWithSelector(PitOracle.NotThePrintForT.selector, t, prevTs, ts));
            oracle.verifyAt(KEEPER_ONLY, t, report);
        }
    }

    // ----------------------------------------------------------------------------------------- general

    function test_revertsOnMalformedOrUnknownReports() public {
        vm.expectRevert(PitOracle.MalformedReport.selector);
        oracle.verifyAt(TSLA, T, "");
        vm.expectRevert(PitOracle.MalformedReport.selector);
        oracle.verifyAt(TSLA, T, hex"01");
        vm.expectRevert(abi.encodeWithSelector(PitOracle.UnknownSource.selector, uint8(3)));
        oracle.verifyAt(TSLA, T, hex"0300");
        vm.expectRevert(abi.encodeWithSelector(PitOracle.UnknownSource.selector, uint8(0)));
        oracle.verifyAt(TSLA, T, hex"0000");
        // A keeper report that does not decode.
        vm.expectRevert();
        oracle.verifyAt(TSLA, T, hex"02deadbeef");
    }

    function test_revertsOnAnUnsupportedTicker() public {
        bytes32 unknown = bytes32("HIMS");
        assertFalse(oracle.supported(unknown));
        bytes memory report = _blob(37065425, 6125, -5, T, T - 1);
        vm.expectRevert(abi.encodeWithSelector(PitOracle.UnsupportedTicker.selector, unknown));
        oracle.verifyAt(unknown, T, report);
    }

    function test_supported() public {
        assertTrue(oracle.supported(TSLA));
        assertTrue(oracle.supported(PYTH_ONLY));
        assertTrue(oracle.supported(KEEPER_ONLY));

        // A Chainlink feed without a signer set is not a source. Dropping the set takes 24 hours.
        vm.prank(owner);
        oracle.setSigners(new address[](0), 0);
        assertTrue(oracle.supported(KEEPER_ONLY), "the old set is in force during the delay");
        vm.warp(NOW + 24 hours);
        assertTrue(oracle.supported(TSLA));
        assertTrue(oracle.supported(PYTH_ONLY));
        assertFalse(oracle.supported(KEEPER_ONLY));

        // Sources are set once, so an all-zero config does not remove a ticker: a ticker is taken out
        // of use by disabling its sources, and the stored feeds never change.
        vm.startPrank(owner);
        vm.expectRevert(PitOracle.SourcePinned.selector);
        oracle.setTicker(TSLA, _cfg(bytes32(0), address(0), address(0)));
        oracle.setSourceDisabled(TSLA, 1, true);
        vm.stopPrank();
        assertFalse(oracle.supported(TSLA));
        assertEq(oracle.config(TSLA).pythFeedId, TSLA_ID);
    }

    // ------------------------------------------------------------------------------------------- owner

    function test_constructor() public {
        assertEq(address(oracle.pyth()), address(pyth));
        assertEq(oracle.owner(), owner);
        vm.expectRevert(PitOracle.ZeroAddress.selector);
        new PitOracle(IPyth(address(0)), owner, signerAddrs, 2, 24 hours);
        vm.expectRevert(PitOracle.ZeroAddress.selector);
        new PitOracle(pyth, address(0), signerAddrs, 2, 24 hours);

        // The constructor's signer set is validated like any other and is in force at once.
        vm.expectRevert(PitOracle.InvalidThreshold.selector);
        new PitOracle(pyth, owner, signerAddrs, 0, 24 hours);
        vm.expectRevert(PitOracle.InvalidThreshold.selector);
        new PitOracle(pyth, owner, signerAddrs, 4, 24 hours);
        vm.expectRevert(PitOracle.InvalidThreshold.selector);
        new PitOracle(pyth, owner, new address[](0), 1, 24 hours);
        address[] memory unsorted = new address[](2);
        unsorted[0] = address(0x2222);
        unsorted[1] = address(0x1111);
        vm.expectRevert(PitOracle.InvalidSigners.selector);
        new PitOracle(pyth, owner, unsorted, 1, 24 hours);
        PitOracle bare = new PitOracle(pyth, owner, new address[](0), 0, 24 hours);
        assertEq(bare.threshold(), 0);
        assertEq(bare.signers().length, 0);
    }

    function test_setTicker_appliesDefaults() public view {
        PitOracle.TickerConfig memory c = oracle.config(TSLA);
        assertEq(c.pythFeedId, TSLA_ID);
        assertEq(c.aggregator, address(feed));
        assertEq(c.stockToken, address(token));
        assertEq(c.maxLag, 30);
        assertEq(c.maxConfBps, 100);
        assertEq(c.boundBps, 60);
        assertEq(c.maxFeedAge, 5 days);
        assertEq(c.closeMaxLag, 300, "a close may be up to five minutes late");
        assertEq(oracle.boundBps(TSLA), 60);
        assertEq(oracle.multiplier(TSLA), token.uiMultiplier());
    }

    function test_setTicker_customValuesAndCaps() public {
        PitOracle.TickerConfig memory c = _cfg(TSLA_ID, address(feed), address(token));
        c.maxLag = 10;
        c.maxConfBps = 50;
        c.boundBps = 80;
        c.maxFeedAge = 1 days;
        c.closeMaxLag = 600;
        vm.startPrank(owner);
        // a change of a configured ticker waits SIGNER_DELAY
        vm.expectEmit(true, false, false, true);
        emit PitOracle.TickerChangeScheduled(TSLA, c, NOW + 24 hours);
        oracle.setTicker(TSLA, c);
        assertEq(oracle.config(TSLA).boundBps, 60, "the old limits are in force during the delay");
        vm.warp(NOW + 24 hours);
        assertEq(oracle.config(TSLA).boundBps, 80);

        c.maxLag = 301;
        vm.expectRevert(PitOracle.InvalidConfig.selector);
        oracle.setTicker(TSLA, c);
        c.maxLag = 10;
        c.maxConfBps = 501;
        vm.expectRevert(PitOracle.InvalidConfig.selector);
        oracle.setTicker(TSLA, c);
        c.maxConfBps = 50;
        // the keeper band can be widened to 1% at most
        c.boundBps = 100;
        oracle.setTicker(TSLA, c);
        c.boundBps = 101;
        vm.expectRevert(PitOracle.InvalidConfig.selector);
        oracle.setTicker(TSLA, c);
        c.boundBps = 80;

        vm.expectRevert(PitOracle.InvalidConfig.selector);
        oracle.setTicker(bytes32(0), c);
        // A stock token without a feed has nothing to scale.
        vm.expectRevert(PitOracle.InvalidConfig.selector);
        oracle.setTicker(TSLA, _cfg(TSLA_ID, address(0), address(token)));
        // A feed with more than 18 decimals, and a token with a zero multiplier.
        MockChainlinkFeed wide = new MockChainlinkFeed(19);
        vm.expectRevert(PitOracle.InvalidConfig.selector);
        oracle.setTicker(TSLA, _cfg(TSLA_ID, address(wide), address(0)));
        MockStockToken zero = new MockStockToken(0);
        vm.expectRevert(PitOracle.InvalidConfig.selector);
        oracle.setTicker(TSLA, _cfg(TSLA_ID, address(feed), address(zero)));
        vm.stopPrank();
    }

    function test_customBoundAndLagAreEnforced() public {
        PitOracle.TickerConfig memory c = _cfg(TSLA_ID, address(feed), address(token));
        c.maxLag = 5;
        c.boundBps = 10;
        vm.prank(owner);
        oracle.setTicker(TSLA, c);
        vm.warp(NOW + 24 hours); // in force after the delay

        // 5.6 bps from the reference passes a 10 bps bound, 15 bps does not.
        oracle.verifyAt(TSLA, T, _report2(oracle, _print(PRICE), 0, 1));
        uint256 far = REF * 10015 / 10000;
        bytes memory report = _report2(oracle, _print(far), 0, 1);
        vm.expectRevert(abi.encodeWithSelector(PitOracle.OutOfBound.selector, far, REF));
        oracle.verifyAt(TSLA, T, report);

        bytes memory late = _blob(37065425, 6125, -5, T + 6, T - 1);
        vm.expectRevert(IPyth.PriceFeedNotFoundWithinRange.selector);
        oracle.verifyAt(TSLA, T, late);
    }

    /// @dev Signer changes take effect only after 24 hours: the assertions of a replaced set hold after
    ///      the delay and their opposites hold during it.
    function test_setSigners() public {
        address[] memory current = oracle.signers();
        assertEq(current.length, 3);
        assertEq(oracle.threshold(), 2);
        for (uint256 i; i < 3; ++i) {
            assertEq(current[i], signerAddrs[i]);
            assertTrue(oracle.isSigner(signerAddrs[i]));
        }

        address[] memory next = new address[](2);
        next[0] = address(0x1111);
        next[1] = address(0x2222);
        uint64 from = NOW + 24 hours;
        vm.prank(owner);
        vm.expectEmit(false, false, false, true);
        emit PitOracle.SignersScheduled(next, 1, from);
        oracle.setSigners(next, 1);

        // During the delay nothing changes: the old set verifies, the new one is only announced.
        bytes memory report = _report2(oracle, _print(PRICE), 0, 1);
        assertEq(oracle.signers().length, 3);
        assertEq(oracle.threshold(), 2);
        assertFalse(oracle.isSigner(address(0x1111)));
        assertTrue(oracle.isSigner(signerAddrs[0]));
        oracle.verifyAt(TSLA, T, report);
        (address[] memory pending, uint256 pendingThreshold, uint64 activeFrom) = oracle.pendingSigners();
        assertEq(pending.length, 2);
        assertEq(pending[1], address(0x2222));
        assertEq(pendingThreshold, 1);
        assertEq(activeFrom, from);
        vm.warp(from - 1);
        oracle.verifyAt(TSLA, T, report);

        // From the announced instant on, replacing the set drops the old members.
        vm.warp(from);
        assertEq(oracle.signers().length, 2);
        assertEq(oracle.threshold(), 1);
        assertTrue(oracle.isSigner(address(0x1111)));
        assertFalse(oracle.isSigner(signerAddrs[0]));
        (pending,, activeFrom) = oracle.pendingSigners();
        assertEq(pending.length, 0);
        assertEq(activeFrom, 0);

        // An old signer's print no longer verifies.
        vm.expectRevert(abi.encodeWithSelector(PitOracle.NotASigner.selector, signerAddrs[0]));
        oracle.verifyAt(TSLA, T, report);
    }

    function test_setSigners_validation() public {
        vm.startPrank(owner);
        address[] memory unsorted = new address[](2);
        unsorted[0] = address(0x2222);
        unsorted[1] = address(0x1111);
        vm.expectRevert(PitOracle.InvalidSigners.selector);
        oracle.setSigners(unsorted, 1);

        address[] memory duplicate = new address[](2);
        duplicate[0] = address(0x1111);
        duplicate[1] = address(0x1111);
        vm.expectRevert(PitOracle.InvalidSigners.selector);
        oracle.setSigners(duplicate, 1);

        address[] memory zero = new address[](1);
        vm.expectRevert(PitOracle.InvalidSigners.selector);
        oracle.setSigners(zero, 1);

        address[] memory many = new address[](33);
        for (uint256 i; i < 33; ++i) {
            many[i] = address(uint160(i + 1));
        }
        vm.expectRevert(PitOracle.InvalidSigners.selector);
        oracle.setSigners(many, 1);

        vm.expectRevert(PitOracle.InvalidThreshold.selector);
        oracle.setSigners(signerAddrs, 0);
        vm.expectRevert(PitOracle.InvalidThreshold.selector);
        oracle.setSigners(signerAddrs, 4);
        vm.expectRevert(PitOracle.InvalidThreshold.selector);
        oracle.setSigners(new address[](0), 1);
        vm.stopPrank();

        // A failed replacement leaves the old set in place, now and after the delay.
        assertEq(oracle.signers().length, 3);
        assertTrue(oracle.isSigner(signerAddrs[2]));
        assertEq(oracle.threshold(), 2);
        (,, uint64 activeFrom) = oracle.pendingSigners();
        assertEq(activeFrom, 0, "nothing was scheduled");
        vm.warp(NOW + 2 days);
        assertEq(oracle.signers().length, 3);
        assertEq(oracle.threshold(), 2);
    }

    /// @dev A threshold change also waits 24 hours.
    function test_setThreshold() public {
        bytes memory report = _report2(oracle, _print(PRICE), 0, 1);
        uint64 from = NOW + 24 hours;
        vm.startPrank(owner);
        vm.expectEmit(false, false, false, true);
        emit PitOracle.SignersScheduled(signerAddrs, 3, from);
        oracle.setThreshold(3);
        assertEq(oracle.threshold(), 2, "not yet");
        vm.expectRevert(PitOracle.InvalidThreshold.selector);
        oracle.setThreshold(0);
        vm.expectRevert(PitOracle.InvalidThreshold.selector);
        oracle.setThreshold(4);
        vm.stopPrank();

        oracle.verifyAt(TSLA, T, report);
        vm.warp(from);
        assertEq(oracle.threshold(), 3);
        assertEq(oracle.signers().length, 3);
        // Two signatures are no longer enough.
        vm.expectRevert(abi.encodeWithSelector(PitOracle.NotEnoughSignatures.selector, 2, 3));
        oracle.verifyAt(TSLA, T, report);
    }

    function test_signerChange_aLoweredThresholdCannotBeRushed() public {
        // The dangerous direction: one compromised signer plus an owner who drops the threshold to 1.
        bytes[] memory one = new bytes[](1);
        one[0] = _sign(oracle, keys[0], _print(PRICE));
        bytes memory report = _report(_print(PRICE), one);
        vm.prank(owner);
        oracle.setThreshold(1);
        vm.expectRevert(abi.encodeWithSelector(PitOracle.NotEnoughSignatures.selector, 1, 2));
        oracle.verifyAt(TSLA, T, report);
        vm.warp(NOW + 24 hours - 1);
        vm.expectRevert(abi.encodeWithSelector(PitOracle.NotEnoughSignatures.selector, 1, 2));
        oracle.verifyAt(TSLA, T, report);
        vm.warp(NOW + 24 hours);
        oracle.verifyAt(TSLA, T, report);
    }

    function test_signerChange_aNewChangeRestartsTheClock_andCanBeCancelled() public {
        address[] memory next = new address[](1);
        next[0] = address(0x1111);
        uint256 start = NOW;
        vm.startPrank(owner);
        oracle.setSigners(next, 1);
        // 23 hours in, the owner schedules something else: the first change never takes effect, and the
        // second waits its own full 24 hours.
        vm.warp(start + 23 hours);
        address[] memory other = new address[](1);
        other[0] = address(0x3333);
        oracle.setSigners(other, 1);
        vm.warp(start + 24 hours + 1);
        assertEq(oracle.signers().length, 3, "the replaced change did not mature");
        vm.warp(start + 47 hours - 1);
        assertEq(oracle.signers().length, 3);

        // cancel: nothing is waiting any more
        oracle.cancelSignerChange();
        vm.expectRevert(PitOracle.NoPendingChange.selector);
        oracle.cancelSignerChange();
        vm.stopPrank();
        vm.warp(start + 10 days);
        assertEq(oracle.signers().length, 3);
        assertEq(oracle.threshold(), 2);
        assertTrue(oracle.isSigner(signerAddrs[0]));
    }

    function test_signerChange_aMaturedChangeIsNotUndoneByTheNextOne() public {
        address[] memory next = new address[](2);
        next[0] = address(0x1111);
        next[1] = address(0x2222);
        vm.startPrank(owner);
        oracle.setSigners(next, 2);
        vm.warp(NOW + 24 hours);
        assertEq(oracle.signers().length, 2);
        // The next change, of the threshold only, is built on the set now in force and waits again.
        oracle.setThreshold(1);
        assertEq(oracle.signers().length, 2, "still the matured set");
        assertEq(oracle.threshold(), 2);
        // Cancelling drops only the waiting threshold change; the matured set stays in force.
        oracle.cancelSignerChange();
        assertEq(oracle.signers().length, 2);
        assertEq(oracle.threshold(), 2);
        vm.warp(NOW + 30 days);
        assertEq(oracle.threshold(), 2);
        vm.stopPrank();
    }

    function test_setThreshold_appliesToTheWaitingSet() public {
        address[] memory next = new address[](2);
        next[0] = address(0x1111);
        next[1] = address(0x2222);
        vm.startPrank(owner);
        oracle.setSigners(next, 2);
        // a threshold of 3 is valid for the set in force but not for the waiting one
        vm.expectRevert(PitOracle.InvalidThreshold.selector);
        oracle.setThreshold(3);
        oracle.setThreshold(1);
        vm.stopPrank();
        vm.warp(NOW + 24 hours);
        assertEq(oracle.signers().length, 2);
        assertEq(oracle.threshold(), 1);
    }

    // --------------------------------------------------------------------------- sources are set once

    function test_setTicker_sourcesAreSetOnce() public {
        MockChainlinkFeed otherFeed = new MockChainlinkFeed(8);
        MockStockToken otherToken = new MockStockToken(1e18);
        vm.startPrank(owner);

        // re-pointing the Pyth feed, the aggregator or the stock token is refused
        vm.expectRevert(PitOracle.SourcePinned.selector);
        oracle.setTicker(TSLA, _cfg(OTHER_ID, address(feed), address(token)));
        vm.expectRevert(PitOracle.SourcePinned.selector);
        oracle.setTicker(TSLA, _cfg(TSLA_ID, address(otherFeed), address(token)));
        vm.expectRevert(PitOracle.SourcePinned.selector);
        oracle.setTicker(TSLA, _cfg(TSLA_ID, address(feed), address(otherToken)));
        vm.expectRevert(PitOracle.SourcePinned.selector);
        oracle.setTicker(TSLA, _cfg(TSLA_ID, address(feed), address(0)));
        // and so is removing one by passing zero
        vm.expectRevert(PitOracle.SourcePinned.selector);
        oracle.setTicker(TSLA, _cfg(bytes32(0), address(feed), address(token)));
        vm.expectRevert(PitOracle.SourcePinned.selector);
        oracle.setTicker(TSLA, _cfg(TSLA_ID, address(0), address(0)));

        // a source that was never set can still be added, once (in force after the delay)
        oracle.setTicker(PYTH_ONLY, _cfg(TSLA_ID, address(feed), address(0)));
        vm.warp(NOW + 24 hours);
        vm.expectRevert(PitOracle.SourcePinned.selector);
        oracle.setTicker(PYTH_ONLY, _cfg(TSLA_ID, address(feed), address(token)));
        oracle.setTicker(KEEPER_ONLY, _cfg(TSLA_ID, address(feed), address(token)));
        vm.warp(NOW + 48 hours);
        vm.expectRevert(PitOracle.SourcePinned.selector);
        oracle.setTicker(KEEPER_ONLY, _cfg(OTHER_ID, address(feed), address(token)));

        // the numeric limits stay adjustable with the same sources
        PitOracle.TickerConfig memory c = _cfg(TSLA_ID, address(feed), address(token));
        c.boundBps = 50;
        oracle.setTicker(TSLA, c);
        vm.warp(NOW + 72 hours);
        assertEq(oracle.config(TSLA).boundBps, 50);
        vm.stopPrank();
    }

    function test_setSourceDisabled() public {
        bytes memory keeperReport = _report2(oracle, _print(PRICE), 0, 1);
        bytes memory pythReport = _blob(37065425, 6125, -5, T, T - 1);

        vm.expectRevert(Ownable.Unauthorized.selector);
        oracle.setSourceDisabled(TSLA, 2, true);
        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(PitOracle.UnknownSource.selector, uint8(3)));
        oracle.setSourceDisabled(TSLA, 3, true);

        vm.expectEmit(true, true, false, true);
        emit PitOracle.SourceDisabledSet(TSLA, 2, true, NOW + 24 hours);
        oracle.setSourceDisabled(TSLA, 2, true);
        vm.expectRevert(abi.encodeWithSelector(PitOracle.SourceIsDisabled.selector, TSLA, uint8(2)));
        oracle.verifyAt(TSLA, T, keeperReport);
        oracle.verifyAt(TSLA, T, pythReport);
        assertTrue(oracle.supported(TSLA), "the Pyth source still counts");

        oracle.setSourceDisabled(TSLA, 1, true);
        assertFalse(oracle.supported(TSLA));
        vm.expectRevert(abi.encodeWithSelector(PitOracle.UnsupportedTicker.selector, TSLA));
        oracle.verifyAt(TSLA, T, pythReport);

        // switched back on, the very same feeds verify again: nothing was re-pointed
        oracle.setSourceDisabled(TSLA, 1, false);
        oracle.setSourceDisabled(TSLA, 2, false);
        vm.stopPrank();
        oracle.verifyAt(TSLA, T, keeperReport);
        oracle.verifyAt(TSLA, T, pythReport);
        assertEq(oracle.config(TSLA).aggregator, address(feed));
    }

    function test_ownerFunctionsAreOwnerOnly() public {
        vm.expectRevert(Ownable.Unauthorized.selector);
        oracle.setTicker(TSLA, _cfg(TSLA_ID, address(0), address(0)));
        vm.expectRevert(Ownable.Unauthorized.selector);
        oracle.setSigners(signerAddrs, 1);
        vm.expectRevert(Ownable.Unauthorized.selector);
        oracle.setThreshold(1);
        vm.expectRevert(Ownable.Unauthorized.selector);
        oracle.cancelSignerChange();
        vm.expectRevert(Ownable.Unauthorized.selector);
        oracle.cancelTickerChange(TSLA);
        vm.expectRevert(Ownable.Unauthorized.selector);
        oracle.setSourceDisabled(TSLA, 1, true);
    }

    // ------------------------------------------------------------- owner changes wait

    /// @dev A change of a configured ticker waits SIGNER_DELAY, shows in `pendingConfig`, replaces a change
    ///      still waiting, and can be cancelled. The views give the configuration in force.
    function test_setTicker_aChangeWaits_andCanBeCancelled() public {
        PitOracle.TickerConfig memory c = _cfg(TSLA_ID, address(feed), address(token));
        c.boundBps = 90;
        c.closeMaxLag = 900;
        vm.prank(owner);
        oracle.setTicker(TSLA, c);
        (PitOracle.TickerConfig memory p, uint64 from) = oracle.pendingConfig(TSLA);
        assertEq(from, NOW + 24 hours);
        assertEq(p.boundBps, 90);
        assertEq(oracle.boundBps(TSLA), 60, "in force: the old bound");
        assertEq(oracle.config(TSLA).closeMaxLag, 300);

        // a second change replaces the first and restarts the clock
        vm.warp(NOW + 1 hours);
        c.boundBps = 70;
        vm.prank(owner);
        oracle.setTicker(TSLA, c);
        (p, from) = oracle.pendingConfig(TSLA);
        assertEq(from, NOW + 25 hours);
        assertEq(p.boundBps, 70);

        // cancelled: nothing changes, ever
        vm.prank(owner);
        vm.expectEmit(true, false, false, false);
        emit PitOracle.TickerChangeCancelled(TSLA);
        oracle.cancelTickerChange(TSLA);
        (, from) = oracle.pendingConfig(TSLA);
        assertEq(from, 0);
        vm.warp(NOW + 3 days);
        assertEq(oracle.boundBps(TSLA), 60);
        vm.prank(owner);
        vm.expectRevert(PitOracle.NoPendingChange.selector);
        oracle.cancelTickerChange(TSLA);

        // one that matures is in force, and the views follow it
        vm.prank(owner);
        oracle.setTicker(TSLA, c);
        vm.warp(NOW + 4 days - 1);
        assertEq(oracle.boundBps(TSLA), 60);
        vm.warp(NOW + 4 days);
        assertEq(oracle.boundBps(TSLA), 70);
        assertEq(oracle.config(TSLA).closeMaxLag, 900);
        (, from) = oracle.pendingConfig(TSLA);
        assertEq(from, 0, "nothing waits once it is in force");
        // a verify writes the matured change in; a later cancel finds nothing
        oracle.verifyCloseAt(TSLA, T, _blob(37065425, 6125, -5, T + 600, T - 1));
        vm.prank(owner);
        vm.expectRevert(PitOracle.NoPendingChange.selector);
        oracle.cancelTickerChange(TSLA);
        assertEq(oracle.boundBps(TSLA), 70);
    }

    /// @dev The fill-in of a missing source waits too: a feed id added to a keeper-only ticker verifies
    ///      nothing for 24 hours (it could not pick the close of a round that is open).
    function test_setTicker_aFillInOfAMissingSourceWaits() public {
        bytes memory pythReport = _blob(37065425, 6125, -5, T, T - 1);
        vm.prank(owner);
        oracle.setTicker(KEEPER_ONLY, _cfg(TSLA_ID, address(feed), address(token)));
        vm.expectRevert(abi.encodeWithSelector(PitOracle.SourceNotConfigured.selector, KEEPER_ONLY, uint8(1)));
        oracle.verifyCloseAt(KEEPER_ONLY, T, pythReport);
        vm.warp(NOW + 24 hours);
        (uint256 price,, bool trustless) = oracle.verifyCloseAt(KEEPER_ONLY, T, pythReport);
        assertGt(price, 0);
        assertTrue(trustless);
    }

    /// @dev The first configuration of a ticker is in force at once (nothing verifies for it before), and
    ///      on a testnet (no delay) every change is.
    function test_setTicker_firstConfigAtOnce_andEverythingAtOnceOnATestnet() public {
        bytes32 fresh = bytes32("AMZN");
        vm.prank(owner);
        vm.expectEmit(true, false, false, false);
        emit PitOracle.TickerSet(fresh, _cfg(TSLA_ID, address(0), address(0)));
        oracle.setTicker(fresh, _cfg(TSLA_ID, address(0), address(0)));
        assertTrue(oracle.supported(fresh));

        PitOracle testnet = new PitOracle(pyth, owner, signerAddrs, 2, 0);
        vm.startPrank(owner);
        testnet.setTicker(TSLA, _cfg(TSLA_ID, address(0), address(0)));
        PitOracle.TickerConfig memory c = _cfg(TSLA_ID, address(feed), address(token));
        c.boundBps = 90;
        testnet.setTicker(TSLA, c);
        vm.stopPrank();
        assertEq(testnet.boundBps(TSLA), 90);
        assertEq(testnet.config(TSLA).aggregator, address(feed));
        (, uint64 from) = testnet.pendingConfig(TSLA);
        assertEq(from, 0);
    }

    /// @dev A source switched off stops fills at once, but refuses only the closes whose instant is at
    ///      least SIGNER_DELAY after the switch: the close of a round open at the switch still verifies,
    ///      however late it is recorded. Switching back on is immediate.
    function test_setSourceDisabled_stopsFillsAtOnce_closesOnlyFromTheDelay() public {
        bytes memory pythAtT = _blob(37065425, 6125, -5, T, T - 1);
        vm.prank(owner);
        oracle.setSourceDisabled(TSLA, 1, true);
        uint64 from = NOW + 24 hours;
        assertTrue(oracle.sourceDisabled(TSLA, 1));
        assertEq(oracle.closesOffFrom(TSLA, 1), from);
        vm.expectRevert(abi.encodeWithSelector(PitOracle.SourceIsDisabled.selector, TSLA, uint8(1)));
        oracle.verifyAt(TSLA, T, pythAtT);
        oracle.verifyCloseAt(TSLA, T, pythAtT);

        // the close of T still verifies days later; a close at or after `from` does not
        vm.warp(NOW + 3 days);
        oracle.verifyCloseAt(TSLA, T, pythAtT);
        oracle.verifyCloseAt(TSLA, from - 1, _blob(37065425, 6125, -5, from - 1, from - 2));
        bytes memory atFrom = _blob(37065425, 6125, -5, from, from - 1);
        vm.expectRevert(abi.encodeWithSelector(PitOracle.SourceIsDisabled.selector, TSLA, uint8(1)));
        oracle.verifyCloseAt(TSLA, from, atFrom);

        // with both sources off, no close at or after `from` is supported, and earlier ones still are
        vm.prank(owner);
        oracle.setSourceDisabled(TSLA, 2, true);
        assertEq(oracle.closesOffFrom(TSLA, 2), NOW + 4 days, "the keeper source's own delay");
        assertFalse(oracle.supported(TSLA));
        oracle.verifyCloseAt(TSLA, T, pythAtT);
        vm.expectRevert(abi.encodeWithSelector(PitOracle.SourceIsDisabled.selector, TSLA, uint8(1)));
        oracle.verifyCloseAt(TSLA, from, atFrom);

        // switching off again keeps the first instant; back on works at once
        vm.prank(owner);
        oracle.setSourceDisabled(TSLA, 1, true);
        assertEq(oracle.closesOffFrom(TSLA, 1), from);
        vm.prank(owner);
        vm.expectEmit(true, true, false, true);
        emit PitOracle.SourceDisabledSet(TSLA, 1, false, 0);
        oracle.setSourceDisabled(TSLA, 1, false);
        assertFalse(oracle.sourceDisabled(TSLA, 1));
        assertEq(oracle.closesOffFrom(TSLA, 1), 0);
        oracle.verifyCloseAt(TSLA, from, atFrom);
        oracle.verifyAt(TSLA, T, pythAtT);
    }

    /// @dev On a testnet (no delay) a source switched off refuses every close at once.
    function test_setSourceDisabled_testnet_closesOffAtOnce() public {
        PitOracle testnet = new PitOracle(pyth, owner, signerAddrs, 2, 0);
        vm.startPrank(owner);
        testnet.setTicker(TSLA, _cfg(TSLA_ID, address(0), address(0)));
        testnet.setSourceDisabled(TSLA, 1, true);
        vm.stopPrank();
        bytes memory pythAtT = _blob(37065425, 6125, -5, T, T - 1);
        vm.expectRevert(abi.encodeWithSelector(PitOracle.UnsupportedTicker.selector, TSLA));
        testnet.verifyCloseAt(TSLA, T, pythAtT);
        vm.expectRevert(abi.encodeWithSelector(PitOracle.UnsupportedTicker.selector, TSLA));
        testnet.verifyAt(TSLA, T, pythAtT);
    }

    function test_printDigestMatchesEip712() public view {
        PitOracle.Print memory p = _print(PRICE);
        bytes32 domain = keccak256(
            abi.encode(
                keccak256(
                    "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
                ),
                keccak256("Fallpit PitOracle"),
                keccak256("1"),
                block.chainid,
                address(oracle)
            )
        );
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Print(bytes32 ticker,uint256 price,uint64 ts,uint64 prevTs)"),
                p.ticker,
                p.price,
                p.ts,
                p.prevTs
            )
        );
        assertEq(oracle.domainSeparator(), domain);
        assertEq(
            oracle.PRINT_TYPEHASH(), keccak256("Print(bytes32 ticker,uint256 price,uint64 ts,uint64 prevTs)")
        );
        assertEq(oracle.printDigest(p), keccak256(abi.encodePacked("\x19\x01", domain, structHash)));
    }
}
