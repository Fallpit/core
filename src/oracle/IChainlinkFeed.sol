// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title IChainlinkFeed
/// @notice The part of a Chainlink push feed proxy (AggregatorV3Interface) that PitOracle uses.
/// @dev Checked against the TSLA feed `0x4A1166a659A55625345e9515b32adECea5547C38` on Robinhood Chain mainnet:
///      8 decimals, round ids increase by one inside a phase, and `getRoundData` of a round that does not
///      exist returns zeros instead of reverting.
interface IChainlinkFeed {
    function decimals() external view returns (uint8);

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);

    function getRoundData(uint80 roundId)
        external
        view
        returns (uint80 roundId_, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}
