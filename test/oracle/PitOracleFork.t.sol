// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PitOracle} from "../../src/PitOracle.sol";
import {IPyth} from "../../src/oracle/IPyth.sol";
import {IChainlinkFeed} from "../../src/oracle/IChainlinkFeed.sol";
import {IStockToken} from "../../src/oracle/IStockToken.sol";
import {OracleTestBase} from "./OracleTestBase.sol";
import {TslaClose20261002} from "./fixtures/TslaClose20261002.sol";

/// @notice Fork tests against Robinhood Chain. They are skipped unless the RPC is given in the environment:
///
///         FORK_RPC_4663=https://rpc.mainnet.chain.robinhood.com \
///         FORK_RPC_46630=https://rpc.testnet.chain.robinhood.com \
///         forge test --match-path "test/oracle/PitOracleFork.t.sol" -vv
///
///         The public RPCs keep no historical state, so the forks are taken at the latest block. Nothing is
///         sent to a live chain: PitOracle is deployed inside the fork only.
contract PitOracleForkTest is OracleTestBase {
    IPyth internal constant PYTH = IPyth(0x8250f4aF4B972684F7b336503E2D6dFeDeB1487a);

    // Robinhood Chain mainnet (4663).
    address internal constant TSLA_FEED = 0x4A1166a659A55625345e9515b32adECea5547C38;
    address internal constant TSLA_TOKEN = 0x322F0929c4625eD5bAd873c95208D54E1c003b2d;
    address internal constant AAPL_FEED = 0x6B22A786bAa607d76728168703a39Ea9C99f2cD0;
    address internal constant AAPL_TOKEN = 0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9;
    address internal constant GME_FEED = 0x27C71df6A64fB476468EdF256CF72c038baB5B67;
    address internal constant GME_TOKEN = 0x1b0E319c6A659F002271B69dB8A7df2F911c153E;

    bytes32 internal constant AAPL = bytes32("AAPL");
    bytes32 internal constant GME = bytes32("GME");

    PitOracle internal oracle;
    /// @dev Chain time at the fork, before any warp.
    uint256 internal forkTime;

    /// @dev Selects a fork of `chainId` and deploys a fresh PitOracle in it, or skips the test.
    function _fork(string memory envName, uint256 chainId) internal {
        string memory rpc = vm.envOr(envName, string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc);
        forkTime = block.timestamp;
        assertEq(block.chainid, chainId, "wrong chain behind the RPC");
        _makeSigners(3);
        oracle = new PitOracle(PYTH, address(this), signerAddrs, 2, 24 hours);
    }

    function _cfg(bytes32 id, address aggregator, address stockToken)
        internal
        pure
        returns (PitOracle.TickerConfig memory c)
    {
        c.pythFeedId = id;
        c.aggregator = aggregator;
        c.stockToken = stockToken;
    }

    /// @dev The real TSLA update for Friday 2026-10-02 16:00:00 New York verifies as the print for that
    ///      instant and for no other.
    function _checkPythTslaClose() internal {
        oracle.setTicker(TSLA, _cfg(TslaClose20261002.FEED_ID, address(0), address(0)));
        bytes memory report = _pythReport(TslaClose20261002.BLOB);
        uint64 t = TslaClose20261002.T;

        uint256 fee = _fee();
        (uint256 price, uint64 ts, bool trustless) = oracle.verifyAt{value: fee}(TSLA, t, report);
        assertEq(price, TslaClose20261002.PRICE_WAD, "price");
        assertEq(price, 370.65425e18);
        assertEq(ts, t, "ts");
        assertTrue(trustless);
        emit log_named_decimal_uint("TSLA close 2026-10-02 (Pyth, verified on chain)", price, 18);
        emit log_named_uint("pyth update fee (wei)", fee);

        // Replayed for a second earlier or later it is not the unique print.
        vm.expectRevert(IPyth.PriceFeedNotFoundWithinRange.selector);
        oracle.verifyAt{value: fee}(TSLA, t - 1, report);
        vm.expectRevert(IPyth.PriceFeedNotFoundWithinRange.selector);
        oracle.verifyAt{value: fee}(TSLA, t + 1, report);

        // Under another ticker's feed id the blob holds nothing.
        oracle.setTicker(AAPL, _cfg(bytes32(uint256(TslaClose20261002.FEED_ID) ^ 1), address(0), address(0)));
        vm.expectRevert(IPyth.PriceFeedNotFoundWithinRange.selector);
        oracle.verifyAt{value: fee}(AAPL, t, report);

        // A corrupted blob does not verify (the last byte is part of the Merkle proof of the price message).
        bytes memory corrupted = _pythReport(TslaClose20261002.BLOB);
        corrupted[corrupted.length - 1] = bytes1(uint8(corrupted[corrupted.length - 1]) ^ 0x01);
        vm.expectRevert();
        oracle.verifyAt{value: fee}(TSLA, t, corrupted);
    }

    function _fee() internal view returns (uint256) {
        bytes[] memory updateData = new bytes[](1);
        updateData[0] = TslaClose20261002.BLOB;
        return PYTH.getUpdateFee(updateData);
    }

    receive() external payable {}

    function test_fork_mainnet_pythTslaClose() public {
        _fork("FORK_RPC_4663", 4663);
        _checkPythTslaClose();
    }

    function test_fork_testnet_pythTslaClose() public {
        _fork("FORK_RPC_46630", 46630);
        _checkPythTslaClose();
    }

    /// @dev Keeper prints against the real TSLA and AAPL push feeds and stock tokens, at the latest round.
    function test_fork_mainnet_keeperPrintBoundedByTheRealFeed() public {
        _fork("FORK_RPC_4663", 4663);
        _checkKeeperAgainstFeed(TSLA, TSLA_FEED, TSLA_TOKEN);
        _checkKeeperAgainstFeed(AAPL, AAPL_FEED, AAPL_TOKEN);
    }

    function _checkKeeperAgainstFeed(bytes32 ticker, address feed, address token) internal {
        oracle.setTicker(ticker, _cfg(bytes32(0), feed, token));
        (, int256 answer,, uint256 updatedAt,) = IChainlinkFeed(feed).latestRoundData();
        uint256 multiplier = IStockToken(token).uiMultiplier();
        assertEq(IChainlinkFeed(feed).decimals(), 8);
        assertGt(answer, 0);
        assertGe(multiplier, 1e18);
        // The feed prices the token: the underlying is the answer divided by the multiplier.
        uint256 underlying = uint256(answer) * 1e10 * 1e18 / multiplier;
        emit log_named_bytes32("ticker", ticker);
        emit log_named_decimal_uint("  push feed answer (token)", uint256(answer), 8);
        emit log_named_decimal_uint("  uiMultiplier", multiplier, 18);
        emit log_named_decimal_uint("  reference (underlying)", underlying, 18);
        emit log_named_uint("  round age at the fork (s)", forkTime - updatedAt);

        // The feed has no heartbeat over a weekend; keep the test meaningful whenever it runs.
        vm.warp(updatedAt + 10);
        uint64 ts = uint64(updatedAt + 5);
        PitOracle.Print memory p =
            PitOracle.Print({ticker: ticker, price: underlying * 1005 / 1000, ts: ts, prevTs: ts - 1});
        (uint256 price, uint64 gotTs, bool trustless) = oracle.verifyAt(ticker, ts, _report2(oracle, p, 0, 1));
        assertEq(price, p.price);
        assertEq(gotTs, ts);
        assertFalse(trustless);

        // 0.8% away is outside the 60 bps bound.
        p.price = underlying * 1008 / 1000;
        bytes memory report = _report2(oracle, p, 0, 1);
        vm.expectRevert(abi.encodeWithSelector(PitOracle.OutOfBound.selector, p.price, underlying));
        oracle.verifyAt(ticker, ts, report);

        // A print before this round is bounded by the previous round, found by walking back.
        (, int256 prevAnswer,, uint256 prevUpdatedAt,) = _previousRound(feed);
        if (prevUpdatedAt != 0) {
            uint256 prevUnderlying = uint256(prevAnswer) * 1e10 * 1e18 / multiplier;
            uint64 prevTs = uint64(prevUpdatedAt);
            PitOracle.Print memory old =
                PitOracle.Print({ticker: ticker, price: prevUnderlying, ts: prevTs, prevTs: prevTs - 1});
            (price,,) = oracle.verifyAt(ticker, prevTs, _report2(oracle, old, 0, 1));
            assertEq(price, prevUnderlying);
            emit log_named_decimal_uint("  previous round reference", prevUnderlying, 18);
        }
    }

    function _previousRound(address feed) internal view returns (uint80, int256, uint256, uint256, uint80) {
        (uint80 roundId,,,,) = IChainlinkFeed(feed).latestRoundData();
        return IChainlinkFeed(feed).getRoundData(roundId - 1);
    }

    /// @dev The real case behind the round walk: GME closed at 24.695 on Friday 2026-10-02 and the push feed
    ///      printed about 25.19 in the post market (16:58 and 17:54). A 16:00 close print must be bounded by
    ///      the round in force at 16:00, not by the latest one. The walk is limited to 64 rounds, so once
    ///      the feed has moved on further this test skips (the RPC has no historical state to fork at).
    function test_fork_mainnet_gmeClosePrintAfterThePostMarketMove() public {
        _fork("FORK_RPC_4663", 4663);
        oracle.setTicker(GME, _cfg(bytes32(0), GME_FEED, GME_TOKEN));
        uint64 t = TslaClose20261002.T;
        PitOracle.Print memory p = PitOracle.Print({ticker: GME, price: 24.695e18, ts: t, prevTs: t - 1});
        bytes memory report = _report2(oracle, p, 0, 1);

        (, int256 latest,, uint256 latestAt,) = IChainlinkFeed(GME_FEED).latestRoundData();
        emit log_named_decimal_uint("GME push feed latest answer", uint256(latest), 8);
        emit log_named_uint("  seconds after the 16:00 close", latestAt > t ? latestAt - t : 0);

        try oracle.verifyAt(GME, t, report) returns (uint256 price, uint64 ts, bool trustless) {
            assertEq(price, 24.695e18);
            assertEq(ts, t);
            assertFalse(trustless);
            emit log_named_decimal_uint("GME 16:00 close print accepted", price, 18);
        } catch (bytes memory err) {
            assertEq(bytes4(err), PitOracle.ChainlinkRoundNotFound.selector, "unexpected revert");
            emit log_string("the feed is more than 64 rounds past 2026-10-02 16:00: skipped");
            vm.skip(true);
        }
    }
}
