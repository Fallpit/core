// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title IAnchorSource
/// @notice Tells which asset a coin was launched against (its anchor), by asking the launchpad that launched
///         it.
interface IAnchorSource {
    /// @return known true when this source's launchpad launched `coin`
    /// @return anchor the asset `coin` was launched against; address(0) is native ETH
    function anchorOf(address coin) external view returns (bool known, address anchor);
}
