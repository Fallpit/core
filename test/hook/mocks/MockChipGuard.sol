// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IChipGuard} from "../../../src/interfaces/IChipGuard.sol";

/// @notice Chip guard with test-set answers.
contract MockChipGuard is IChipGuard {
    mapping(address chip => bool) public allowed;
    mapping(address chip => bool) public taxed;

    function set(address chip, bool allowed_, bool feeOnTransfer) external {
        allowed[chip] = allowed_;
        taxed[chip] = feeOnTransfer;
    }

    function check(address chip) external view returns (bool, bool) {
        return (allowed[chip], taxed[chip]);
    }
}
