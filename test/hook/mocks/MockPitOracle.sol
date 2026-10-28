// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPitOracle} from "../../../src/interfaces/IPitOracle.sol";

/// @title MockPitOracle
/// @notice Models the one property the hook relies on: for an instant `t` exactly one print of a source
///         qualifies (prevTs < t <= ts <= t + maxLag). Tests post prints into a per-source chain with
///         strictly increasing timestamps; a report is just a pointer `(ticker, source, index)`, so a
///         caller can offer any posted print but only the unique qualifying one verifies.
/// @dev Source 1 is trustless (stands for Pyth), source 2 is not (stands for the keeper set).
contract MockPitOracle is IPitOracle {
    struct Print {
        uint256 price;
        uint64 ts;
    }

    uint8 public constant TRUSTLESS = 1;
    uint8 public constant KEEPER = 2;
    uint64 public constant MAX_LAG = 30;
    uint64 public constant CLOSE_MAX_LAG = 300;

    mapping(bytes32 ticker => mapping(uint8 source => Print[])) internal _prints;
    mapping(bytes32 ticker => bool) public supported;
    /// @notice Update fee charged per verification (0 by default, like Pyth on Robinhood Chain today).
    uint256 public fee;

    error UnknownSource();
    error NotIncreasing();
    error WrongTicker();
    error NotThePrint();
    error FeeNotPaid();

    function setSupported(bytes32 ticker, bool yes) external {
        supported[ticker] = yes;
    }

    function setFee(uint256 fee_) external {
        fee = fee_;
    }

    /// @notice Appends a print to a source's chain and returns the report that points at it.
    function post(bytes32 ticker, uint8 source, uint256 price, uint64 ts) external returns (bytes memory) {
        if (source != TRUSTLESS && source != KEEPER) revert UnknownSource();
        Print[] storage chain = _prints[ticker][source];
        if (chain.length != 0 && chain[chain.length - 1].ts >= ts) revert NotIncreasing();
        chain.push(Print(price, ts));
        return abi.encode(ticker, source, chain.length - 1);
    }

    function printCount(bytes32 ticker, uint8 source) external view returns (uint256) {
        return _prints[ticker][source].length;
    }

    /// @inheritdoc IPitOracle
    function verifyAt(bytes32 ticker, uint64 t, bytes calldata report)
        external
        payable
        returns (uint256 priceWad, uint64 ts, bool trustless)
    {
        return _verify(ticker, t, report, MAX_LAG);
    }

    /// @inheritdoc IPitOracle
    function verifyCloseAt(bytes32 ticker, uint64 t, bytes calldata report)
        external
        payable
        returns (uint256 priceWad, uint64 ts, bool trustless)
    {
        return _verify(ticker, t, report, CLOSE_MAX_LAG);
    }

    /// @inheritdoc IPitOracle
    function boundBps(bytes32) external pure returns (uint256) {
        return 60;
    }

    /// @inheritdoc IPitOracle
    function multiplier(bytes32) external pure returns (uint256) {
        return 1e18;
    }

    function _verify(bytes32 ticker, uint64 t, bytes calldata report, uint64 lag)
        internal
        returns (uint256 priceWad, uint64 ts, bool trustless)
    {
        if (msg.value < fee) revert FeeNotPaid();
        (bytes32 reportTicker, uint8 source, uint256 index) = abi.decode(report, (bytes32, uint8, uint256));
        if (reportTicker != ticker) revert WrongTicker();
        Print[] storage chain = _prints[ticker][source];
        Print memory p = chain[index];
        uint64 prevTs = index == 0 ? 0 : chain[index - 1].ts;
        if (!(prevTs < t && t <= p.ts && p.ts <= t + lag)) revert NotThePrint();
        if (msg.value > fee) {
            (bool ok,) = msg.sender.call{value: msg.value - fee}("");
            require(ok, "refund failed");
        }
        return (p.price, p.ts, source == TRUSTLESS);
    }
}
