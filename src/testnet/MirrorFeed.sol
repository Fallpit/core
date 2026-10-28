// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IChainlinkFeed} from "../oracle/IChainlinkFeed.sol";
import {IStockToken} from "../oracle/IStockToken.sol";

/// @title MirrorFeed
/// @notice Testnet stand-in for a Chainlink push feed of a stock token. Robinhood Chain testnet (46630)
///         has no stock price feeds, so a keeper copies the rounds of the mainnet (4663) feed here, each
///         with its original answer and time. `PitOracle` then bounds keeper prints on testnet exactly as
///         it does on mainnet.
/// @dev Testnet only: whoever holds the pusher key decides the bound. Round ids follow the shape of a
///      Chainlink proxy (phase 1, aggregator rounds from 1) and a round that does not exist reads as zeros,
///      as the real proxy answers on Robinhood Chain. Rounds are append-only and their times never go back.
contract MirrorFeed is IChainlinkFeed {
    struct Round {
        int256 answer;
        uint64 updatedAt;
    }

    uint80 internal constant PHASE = uint80(1) << 64;

    /// @inheritdoc IChainlinkFeed
    uint8 public immutable decimals;
    /// @notice May name the pusher.
    address public immutable owner;
    /// @notice The keeper address that may push rounds.
    address public pusher;
    /// @notice For example "TSLA / USD (mirror of 4663)".
    string public description;

    Round[] internal _rounds;

    event PusherSet(address indexed pusher);
    event RoundPushed(uint80 indexed roundId, int256 answer, uint256 updatedAt);

    error OnlyOwner();
    error OnlyPusher();
    error ZeroAddress();
    error BadDecimals();
    error BadAnswer();
    error BadTime();

    /// @param decimals_ decimals of the mirrored feed (8 for the stock feeds on 4663)
    /// @param owner_ may change the pusher
    /// @param pusher_ the keeper address that copies the rounds
    constructor(uint8 decimals_, string memory description_, address owner_, address pusher_) {
        if (owner_ == address(0) || pusher_ == address(0)) revert ZeroAddress();
        if (decimals_ > 18) revert BadDecimals();
        decimals = decimals_;
        description = description_;
        owner = owner_;
        pusher = pusher_;
        emit PusherSet(pusher_);
    }

    /// @notice Names a new pusher.
    function setPusher(address pusher_) external {
        if (msg.sender != owner) revert OnlyOwner();
        if (pusher_ == address(0)) revert ZeroAddress();
        pusher = pusher_;
        emit PusherSet(pusher_);
    }

    /// @notice Appends a round copied from the mirrored feed.
    /// @param answer the round's answer, positive
    /// @param updatedAt the round's own time on the mirrored chain: not in the future and not before the
    ///        previous round here
    /// @return roundId id of the new round
    function push(int256 answer, uint256 updatedAt) external returns (uint80 roundId) {
        if (msg.sender != pusher) revert OnlyPusher();
        if (answer <= 0) revert BadAnswer();
        uint256 n = _rounds.length;
        if (updatedAt == 0 || updatedAt > block.timestamp || (n != 0 && updatedAt < _rounds[n - 1].updatedAt))
        {
            revert BadTime();
        }
        _rounds.push(Round(answer, uint64(updatedAt)));
        roundId = PHASE | uint80(n + 1);
        emit RoundPushed(roundId, answer, updatedAt);
    }

    /// @notice AggregatorV3 version field.
    function version() external pure returns (uint256) {
        return 1;
    }

    /// @notice Number of rounds pushed so far.
    function roundCount() external view returns (uint256) {
        return _rounds.length;
    }

    /// @inheritdoc IChainlinkFeed
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return getRoundData(PHASE | uint80(_rounds.length));
    }

    /// @inheritdoc IChainlinkFeed
    function getRoundData(uint80 roundId) public view returns (uint80, int256, uint256, uint256, uint80) {
        uint256 n = uint64(roundId);
        if (roundId >> 64 != 1 || n == 0 || n > _rounds.length) return (roundId, 0, 0, 0, roundId);
        Round memory r = _rounds[n - 1];
        return (roundId, r.answer, r.updatedAt, r.updatedAt, roundId);
    }
}

/// @title MirrorStockToken
/// @notice Testnet stub of a Robinhood stock token: only `uiMultiplier()`, copied from mainnet by the same
///         keeper. `PitOracle` divides the feed's answer by it to get the price of the underlying stock.
contract MirrorStockToken is IStockToken {
    /// @notice The feed whose pusher may update the multiplier.
    MirrorFeed public immutable feed;
    /// @inheritdoc IStockToken
    uint256 public uiMultiplier;

    event MultiplierSet(uint256 multiplier);

    error OnlyPusher();
    error BadMultiplier();

    /// @param feed_ the mirror feed of the same stock; its pusher maintains the multiplier
    /// @param multiplier shares of the underlying per token, WAD (1e18 until a corporate action)
    constructor(MirrorFeed feed_, uint256 multiplier) {
        if (multiplier == 0) revert BadMultiplier();
        feed = feed_;
        uiMultiplier = multiplier;
        emit MultiplierSet(multiplier);
    }

    /// @notice Copies a new multiplier from mainnet.
    function setMultiplier(uint256 multiplier) external {
        if (msg.sender != feed.pusher()) revert OnlyPusher();
        if (multiplier == 0) revert BadMultiplier();
        uiMultiplier = multiplier;
        emit MultiplierSet(multiplier);
    }
}
