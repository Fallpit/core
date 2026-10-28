// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FallpitHook} from "../src/FallpitHook.sol";

interface IBalanceOf {
    function balanceOf(address owner) external view returns (uint256);
}

/// @notice The hook's accounting invariant, read from outside (the hook does not carry the view, for its
///         size): the chips it holds in its own balance, and what it owes.
///         held >= owed always.
library Accounting {
    function read(address hook, address chip) internal view returns (uint256 claims, uint256 owed) {
        FallpitHook h = FallpitHook(payable(hook));
        return (IBalanceOf(chip).balanceOf(hook), h.chipOwed(chip));
    }
}
