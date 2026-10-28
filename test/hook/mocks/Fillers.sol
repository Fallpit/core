// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FallpitRouter} from "../../../src/FallpitRouter.sol";

interface IApprovable {
    function approve(address spender, uint256 amount) external returns (bool);
}

/// @notice A contract that trades and fills but does not take native coin unless told to: its `receive`
///         reverts. Used as a filler whose fill fee cannot be delivered, and as a trader whose refunded
///         fill fee cannot be delivered.
contract RevertingFiller {
    FallpitRouter public immutable router;
    bool public accepts;

    constructor(FallpitRouter router_) payable {
        router = router_;
    }

    receive() external payable {
        if (!accepts) revert("no coin here");
    }

    function setAccepts(bool on) external {
        accepts = on;
    }

    function approve(address token, address spender) external {
        IApprovable(token).approve(spender, type(uint256).max);
    }

    function commit(bytes32 roundId, uint8 index, bool isBuy, uint256 shares, uint256 limit, uint256 fee)
        external
        returns (uint256)
    {
        return router.commit{value: fee}(roundId, index, isBuy, shares, limit);
    }

    function fill(uint256 id, bytes calldata report) external payable returns (bool) {
        return router.fill{value: msg.value}(id, report);
    }

    function claim(address to) external returns (uint256) {
        return router.claimEth(to);
    }
}

/// @notice A filler whose `receive` burns every unit of gas it is given.
contract GuzzlingFiller {
    FallpitRouter public immutable router;
    uint256 internal _sink;

    constructor(FallpitRouter router_) {
        router = router_;
    }

    receive() external payable {
        while (true) {
            ++_sink;
        }
    }

    function fill(uint256 id, bytes calldata report) external returns (bool) {
        return router.fill(id, report);
    }

    function claim(address to) external returns (uint256) {
        return router.claimEth(to);
    }
}

/// @notice A filler that, while it is being paid its fill fee, tries to get back into the router: to fill
///         a second commit (and be paid again), to refund it, to claim, and to commit. It records which of
///         the four calls got through and never reverts the payment itself.
contract ReentrantFiller {
    FallpitRouter public immutable router;
    uint256 public targetId;
    bytes public targetReport;
    bytes32 public roundId;
    uint256 public fee;
    /// @dev One packed word, because the receiver only has the router's gas allowance: bits 0..63 how
    ///      many times `receive` ran, bits 64..127 the calls that got through, bits 128..159 the selector
    ///      the last blocked call reverted with.
    uint256 internal _record;

    constructor(FallpitRouter router_) payable {
        router = router_;
    }

    function arm(uint256 targetId_, bytes calldata targetReport_, bytes32 roundId_, uint256 fee_) external {
        targetId = targetId_;
        targetReport = targetReport_;
        roundId = roundId_;
        fee = fee_;
    }

    receive() external payable {
        uint256 mask;
        bytes4 last;
        bytes[4] memory calls = [
            abi.encodeCall(router.fill, (targetId, targetReport)),
            abi.encodeCall(router.refund, (targetId)),
            abi.encodeCall(router.claimEth, (address(this))),
            abi.encodeCall(router.commit, (roundId, 2, true, 1e18, 1e18))
        ];
        for (uint256 i; i < 4; ++i) {
            (bool ok, bytes memory ret) = address(router).call{value: i == 3 ? fee : 0}(calls[i]);
            if (ok) mask |= 1 << i;
            else if (ret.length >= 4) last = bytes4(ret);
        }
        _record = (uint64(_record) + 1) | mask << 64 | uint256(uint32(last)) << 128;
    }

    /// @notice How many times `receive` ran.
    function paidCalls() external view returns (uint256) {
        return uint64(_record);
    }

    /// @notice Bit i is set when reentrant call i got through (0 fill, 1 refund, 2 claimEth, 3 commit).
    function successes() external view returns (uint256) {
        return uint64(_record >> 64);
    }

    /// @notice Selector the last blocked call reverted with.
    function lastRevert() external view returns (bytes4) {
        return bytes4(uint32(_record >> 128));
    }

    function fill(uint256 id, bytes calldata report) external returns (bool) {
        return router.fill(id, report);
    }
}
