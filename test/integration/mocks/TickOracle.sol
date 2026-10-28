// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPitOracle} from "../../../src/interfaces/IPitOracle.sol";

/// @notice A one-print-per-second feed per source. The print for instant `t` is the print
///         at exactly `t` (prevTs = t - 1 < t <= ts = t), so exactly one print per source qualifies, as in
///         PitOracle. A report is `abi.encode(uint8 source)`; source 1 is trustless, source 2 is the keeper.
/// @dev Prices are set per (ticker, source, ts); a missing print reverts (models a feed with no update).
contract TickOracle is IPitOracle {
    mapping(bytes32 ticker => mapping(uint8 source => mapping(uint64 ts => uint256))) public priceAt;
    mapping(bytes32 ticker => bool) public supported;
    mapping(bytes32 ticker => uint256) internal _multiplier;
    /// @notice A close is verified with this lag (the oracle's default `closeMaxLag`): the close print for
    ///         t is the first print set at or after t, at most this late.
    uint64 public constant CLOSE_MAX_LAG = 300;

    error NoPrint();

    /// @notice The stock token's multiplier the book sees (1e18 unless set).
    function setMultiplier(bytes32 ticker, uint256 m) external {
        _multiplier[ticker] = m;
    }

    function multiplier(bytes32 ticker) external view returns (uint256) {
        uint256 m = _multiplier[ticker];
        return m == 0 ? 1e18 : m;
    }

    function boundBps(bytes32) external pure returns (uint256) {
        return 60;
    }

    /// @notice The close: the first print set in `[t, t + CLOSE_MAX_LAG]` (the feed has no print in the
    ///         seconds it skips, so the first one after a gap covers them).
    function verifyCloseAt(bytes32 ticker, uint64 t, bytes calldata report)
        external
        payable
        returns (uint256 priceWad, uint64 ts, bool trustless)
    {
        uint8 source = abi.decode(report, (uint8));
        for (ts = t; ts <= t + CLOSE_MAX_LAG; ++ts) {
            priceWad = priceAt[ticker][source][ts];
            if (priceWad != 0) break;
        }
        if (priceWad == 0) revert NoPrint();
        if (msg.value != 0) {
            (bool ok,) = msg.sender.call{value: msg.value}("");
            require(ok, "refund failed");
        }
        return (priceWad, ts, source == 1);
    }

    function setSupported(bytes32 ticker, bool yes) external {
        supported[ticker] = yes;
    }

    function set(bytes32 ticker, uint8 source, uint64 ts, uint256 price) external {
        priceAt[ticker][source][ts] = price;
    }

    function verifyAt(bytes32 ticker, uint64 t, bytes calldata report)
        external
        payable
        returns (uint256 priceWad, uint64 ts, bool trustless)
    {
        uint8 source = abi.decode(report, (uint8));
        priceWad = priceAt[ticker][source][t];
        if (priceWad == 0) revert NoPrint();
        if (msg.value != 0) {
            (bool ok,) = msg.sender.call{value: msg.value}("");
            require(ok, "refund failed");
        }
        return (priceWad, t, source == 1);
    }
}
