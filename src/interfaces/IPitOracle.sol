// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title IPitOracle
/// @notice Free price verification for stock tickers. See contracts/SPEC.md section 4.
interface IPitOracle {
    /// @notice Verifies `report` as the one price that counts for instant `t`: the first print with
    ///         prevTs < t <= ts <= t + maxLag(ticker). Exactly one print qualifies, so nobody chooses it.
    /// @dev Reverts when `report` is not that print, is malformed, or fails a bound.
    /// @param ticker stock ticker, left-aligned ASCII, e.g. bytes32("NVDA")
    /// @param t the instant, unix seconds
    /// @param report encoded report; the first byte selects the source (see SPEC)
    /// @return priceWad price of the underlying stock in USD, WAD
    /// @return ts timestamp of the print
    /// @return trustless true when the print is verified by the publisher network's own signatures (Pyth),
    ///         false when it is signed by the keeper set and only bounded by the Chainlink push feed
    function verifyAt(bytes32 ticker, uint64 t, bytes calldata report)
        external
        payable
        returns (uint256 priceWad, uint64 ts, bool trustless);

    /// @notice `verifyAt` for a close: the same rule with the ticker's `closeMaxLag` (default 300 s) in place
    ///         of `maxLag`. The first print with prevTs < t <= ts <= t + closeMaxLag; still exactly one.
    function verifyCloseAt(bytes32 ticker, uint64 t, bytes calldata report)
        external
        payable
        returns (uint256 priceWad, uint64 ts, bool trustless);

    /// @notice Largest distance of a keeper print from its Chainlink reference for `ticker`, basis points.
    function boundBps(bytes32 ticker) external view returns (uint256);

    /// @notice The `uiMultiplier` of the ticker's stock token now, WAD (1e18 when it has none). It changes
    ///         with a corporate action (a split), and the book does not step the variance across a change.
    function multiplier(bytes32 ticker) external view returns (uint256);

    /// @notice True when the ticker has at least one configured source in force that is not switched off
    ///         (the switch for fills, which acts at once).
    function supported(bytes32 ticker) external view returns (bool);
}
