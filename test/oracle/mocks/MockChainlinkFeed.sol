// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IChainlinkFeed} from "../../../src/oracle/IChainlinkFeed.sol";

/// @title MockChainlinkFeed
/// @notice Stand-in for a Chainlink push feed proxy: phase 1, aggregator rounds from 1, and zeros for a
///         round that does not exist (as the real proxy answers on Robinhood Chain).
contract MockChainlinkFeed is IChainlinkFeed {
    struct Round {
        int256 answer;
        uint256 updatedAt;
    }

    uint80 internal constant PHASE = uint80(1) << 64;

    uint8 public immutable decimals;
    Round[] internal _rounds;

    constructor(uint8 decimals_) {
        decimals = decimals_;
    }

    /// @notice Appends a round.
    function push(int256 answer, uint256 updatedAt) external {
        _rounds.push(Round(answer, updatedAt));
    }

    function roundCount() external view returns (uint256) {
        return _rounds.length;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return getRoundData(PHASE | uint80(_rounds.length));
    }

    function getRoundData(uint80 roundId) public view returns (uint80, int256, uint256, uint256, uint80) {
        uint256 n = uint64(roundId);
        if (roundId >> 64 != 1 || n == 0 || n > _rounds.length) return (roundId, 0, 0, 0, roundId);
        Round memory r = _rounds[n - 1];
        return (roundId, r.answer, r.updatedAt, r.updatedAt, roundId);
    }
}
