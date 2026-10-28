// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title IStockToken
/// @notice The part of a Robinhood stock token that PitOracle uses.
interface IStockToken {
    /// @notice Shares of the underlying stock per token, WAD (draft ERC-8056). 1e18 until a dividend or a
    ///         corporate action changes it. The Chainlink push feed prices the token, which is the
    ///         underlying price times this multiplier.
    function uiMultiplier() external view returns (uint256);
}
