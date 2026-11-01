// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {DeployMainnet} from "../../script/DeployMainnet.s.sol";
import {IPitBook} from "../../src/hook/IPitBook.sol";

/// @notice The launch deploys every ticker `KeeperOnly` with no Pyth feed (one close source), and keeps the
///         feed ids for the later config change.
contract MainnetTickerTableTest is Test {
    function test_launch_noPythFeed_everyTickerKeeperOnly() public {
        DeployMainnet script = new DeployMainnet();
        assertFalse(script.PYTH_AT_LAUNCH());
        DeployMainnet.TickerRow[] memory launch = script.tickerTable();
        DeployMainnet.TickerRow[] memory later = script.pythTable();
        assertEq(launch.length, later.length);
        for (uint256 i; i < launch.length; ++i) {
            assertEq(launch[i].pythFeedId, bytes32(0), launch[i].symbol);
            assertEq(uint8(launch[i].fillSource), uint8(IPitBook.FillSource.KeeperOnly), launch[i].symbol);
            assertTrue(launch[i].aggregator != address(0), "a Chainlink bound for every keeper print");
            assertTrue(later[i].pythFeedId != bytes32(0), "the feed id is kept for later");
            assertEq(launch[i].symbol, later[i].symbol);
        }
    }
}
