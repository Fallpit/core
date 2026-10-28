// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";

/// @notice A third party with its own `unlock`: runs any list of PoolManager calls inside the unlocked
///         session, the way an attacker's router would. Reverts with the first failing call's data.
contract PoolManagerCaller is IUnlockCallback {
    IPoolManager public immutable pm;

    constructor(IPoolManager pm_) {
        pm = pm_;
    }

    function run(bytes[] memory calls) external returns (bytes[] memory) {
        return abi.decode(pm.unlock(abi.encode(calls)), (bytes[]));
    }

    function run1(bytes memory call_) external returns (bytes memory) {
        bytes[] memory calls = new bytes[](1);
        calls[0] = call_;
        return abi.decode(pm.unlock(abi.encode(calls)), (bytes[]))[0];
    }

    /// @notice Sets a target other than the PoolManager for call `index` of the next `run` (for example a
    ///         token transfer between `sync` and `settle`).
    mapping(uint256 index => address) public targetOf;

    function setTarget(uint256 index, address target) external {
        targetOf[index] = target;
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(pm), "only pm");
        bytes[] memory calls = abi.decode(data, (bytes[]));
        bytes[] memory results = new bytes[](calls.length);
        for (uint256 i; i < calls.length; ++i) {
            address target = targetOf[i] == address(0) ? address(pm) : targetOf[i];
            (bool ok, bytes memory ret) = target.call(calls[i]);
            if (!ok) {
                assembly ("memory-safe") {
                    revert(add(ret, 0x20), mload(ret))
                }
            }
            results[i] = ret;
        }
        return abi.encode(results);
    }
}
