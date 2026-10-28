// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {console} from "forge-std/Script.sol";
import {LibString} from "solady/utils/LibString.sol";
import {PoolManager} from "v4-core/PoolManager.sol";

import {DeployTestnet} from "./DeployTestnet.s.sol";
import {MirrorFeed, MirrorStockToken} from "../src/testnet/MirrorFeed.sol";
import {MockPyth} from "../test/oracle/mocks/MockPyth.sol";
import {MockFeesManager} from "../test/vault/mocks/MockFeesManager.sol";

/// @title DeployLocal
/// @notice Local anvil only (chain 31337): the whole system as `DeployTestnet` deploys it, on a fresh v4
///         PoolManager and a mock Pyth contract, plus what the keeper's end-to-end test needs from the
///         outside world: for every ticker a second feed and stock token stub that stand in for the
///         mainnet Chainlink feed (the keeper's mirror copies its rounds into the ticker's MirrorFeed),
///         and a mock Doppler fees manager for the harvest.
/// @dev Run with `--sig "runLocal()"`. Reads the same environment variables as `DeployTestnet`, plus
///      SOURCE_PUSHER: the account that plays Chainlink and writes the stand-in mainnet rounds (default:
///      the deployer). Every address is printed as `name address` for the test harness to read.
contract DeployLocal is DeployTestnet {
    error NotLocal(uint256 chainId);

    function runLocal() external {
        if (block.chainid != 31337) revert NotLocal(block.chainid);
        uint256 key = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(key);
        Config memory cfg = configFromEnv(deployer);
        address sourcePusher = vm.envOr("SOURCE_PUSHER", deployer);

        vm.startBroadcast(key);
        cfg.poolManager = address(new PoolManager(deployer));
        cfg.pyth = address(new MockPyth());
        System memory s = _deployAll(cfg, deployer);

        uint256 n = cfg.tickers.length;
        MirrorFeed[] memory sourceFeeds = new MirrorFeed[](n);
        MirrorStockToken[] memory sourceTokens = new MirrorStockToken[](n);
        for (uint256 i; i < n; ++i) {
            sourceFeeds[i] =
                new MirrorFeed(FEED_DECIMALS, "stand-in for the mainnet feed", deployer, sourcePusher);
            sourceTokens[i] = new MirrorStockToken(sourceFeeds[i], 1e18);
        }
        MockFeesManager feesManager = new MockFeesManager(false);
        vm.stopBroadcast();

        _log(cfg, s, deployer);
        console.log("PoolManager", cfg.poolManager);
        console.log("MockPyth", cfg.pyth);
        console.log("MockFeesManager", address(feesManager));
        for (uint256 i; i < n; ++i) {
            string memory name = LibString.fromSmallString(cfg.tickers[i].ticker);
            console.log(string.concat("SourceFeed ", name), address(sourceFeeds[i]));
            console.log(string.concat("SourceToken ", name), address(sourceTokens[i]));
        }
    }
}
