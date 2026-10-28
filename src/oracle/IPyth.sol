// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title IPyth
/// @notice The part of the Pyth core contract that PitOracle uses.
/// @dev Struct layout and selectors match the deployed core contract
///      `0x8250f4aF4B972684F7b336503E2D6dFeDeB1487a` (Pyth 1.4.5-alpha.1) on Robinhood Chain mainnet 4663
///      and testnet 46630: a TSLA update for 1790971200 decodes to price 37065425, conf 6125, expo -5,
///      publishTime 1790971200.
interface IPyth {
    /// @dev `price * 10^expo` is the price, `conf * 10^expo` its confidence interval.
    struct Price {
        int64 price;
        uint64 conf;
        int32 expo;
        uint256 publishTime;
    }

    struct PriceFeed {
        bytes32 id;
        Price price;
        Price emaPrice;
    }

    /// @notice Raised (selector 0x45805f5d) when no update in `updateData` has
    ///         `minPublishTime <= publishTime <= maxPublishTime` and, for the unique variant,
    ///         `prevPublishTime < minPublishTime`.
    error PriceFeedNotFoundWithinRange();

    /// @notice Fee in wei for verifying `updateData`.
    function getUpdateFee(bytes[] calldata updateData) external view returns (uint256 feeAmount);

    /// @notice Verifies `updateData` and returns the feeds in `priceIds`, each from the first update at or
    ///         after `minPublishTime`: `prevPublishTime < minPublishTime <= publishTime <= maxPublishTime`.
    ///         Stores nothing. Reverts when a feed has no such update.
    function parsePriceFeedUpdatesUnique(
        bytes[] calldata updateData,
        bytes32[] calldata priceIds,
        uint64 minPublishTime,
        uint64 maxPublishTime
    ) external payable returns (PriceFeed[] memory priceFeeds);
}
