// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPyth} from "../../../src/oracle/IPyth.sol";

/// @title MockPyth
/// @notice Stand-in for the Pyth core contract with the same acceptance rule as the real
///         `parsePriceFeedUpdatesUnique`. An update blob is `abi.encode(PriceFeed, uint64 prevPublishTime)`.
contract MockPyth is IPyth {
    error InsufficientFee();

    /// @notice Fee per update, in wei.
    uint256 public feePerUpdate;
    /// @notice When set, every returned feed carries this id instead of the requested one (a lying core).
    bytes32 public forcedId;

    function setFee(uint256 fee) external {
        feePerUpdate = fee;
    }

    function setForcedId(bytes32 id) external {
        forcedId = id;
    }

    /// @notice Builds an update blob.
    function encode(
        bytes32 id,
        int64 price,
        uint64 conf,
        int32 expo,
        uint64 publishTime,
        uint64 prevPublishTime
    ) external pure returns (bytes memory) {
        Price memory p = Price({price: price, conf: conf, expo: expo, publishTime: publishTime});
        return abi.encode(PriceFeed({id: id, price: p, emaPrice: p}), prevPublishTime);
    }

    function getUpdateFee(bytes[] calldata updateData) public view returns (uint256) {
        return feePerUpdate * updateData.length;
    }

    function parsePriceFeedUpdatesUnique(
        bytes[] calldata updateData,
        bytes32[] calldata priceIds,
        uint64 minPublishTime,
        uint64 maxPublishTime
    ) external payable returns (PriceFeed[] memory feeds) {
        if (msg.value < getUpdateFee(updateData)) revert InsufficientFee();
        feeds = new PriceFeed[](priceIds.length);
        for (uint256 i; i < priceIds.length; ++i) {
            bool found;
            for (uint256 j; j < updateData.length; ++j) {
                (PriceFeed memory feed, uint64 prev) = abi.decode(updateData[j], (PriceFeed, uint64));
                if (
                    feed.id == priceIds[i] && feed.price.publishTime >= minPublishTime
                        && feed.price.publishTime <= maxPublishTime && prev < minPublishTime
                ) {
                    feeds[i] = feed;
                    found = true;
                    break;
                }
            }
            if (!found) revert PriceFeedNotFoundWithinRange();
            if (forcedId != bytes32(0)) feeds[i].id = forcedId;
        }
    }
}
