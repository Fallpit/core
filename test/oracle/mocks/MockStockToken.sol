// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IStockToken} from "../../../src/oracle/IStockToken.sol";

/// @title MockStockToken
/// @notice Stand-in for a Robinhood stock token: only `uiMultiplier()`.
contract MockStockToken is IStockToken {
    uint256 public uiMultiplier;

    constructor(uint256 multiplier) {
        uiMultiplier = multiplier;
    }

    function setMultiplier(uint256 multiplier) external {
        uiMultiplier = multiplier;
    }
}
