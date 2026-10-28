// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title IChipGuard
/// @notice Decides which coins may be a chip (the token a market is traded and housed in).
///         See contracts/SPEC.md section 6.
interface IChipGuard {
    /// @return allowed true when `chip` may open houses and rounds; never true for a fee-on-transfer coin
    /// @return feeOnTransfer true when `chip` is flagged: its transfers deliver less than the amount sent
    function check(address chip) external view returns (bool allowed, bool feeOnTransfer);
}
