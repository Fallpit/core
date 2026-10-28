// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPitVault} from "../../../src/interfaces/IPitVault.sol";
import {IPitOracle} from "../../../src/interfaces/IPitOracle.sol";

interface IERC20Like {
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address owner) external view returns (uint256);
}

/// @notice Stand-in for the Fallpit hook: pulls a house's capital into itself and returns any amount.
contract MockHook {
    IPitVault public vault;

    function setVault(IPitVault vault_) external {
        vault = vault_;
    }

    /// @notice Starts a round: the capital lands in this contract.
    function pull(bytes32 house) external returns (uint256 sent) {
        return vault.pullRoundCapital(house, address(this));
    }

    /// @notice Ends a round: sends `amount` of `chip` back and books it, in one transaction.
    function giveBack(bytes32 house, address chip, uint256 amount) external returns (uint256 received) {
        if (amount != 0) IERC20Like(chip).transfer(address(vault), amount);
        return vault.returnRoundCapital(house);
    }
}

/// @notice Oracle mock: only `supported` matters to the vault.
contract MockOracle is IPitOracle {
    mapping(bytes32 => bool) public supported;

    function setSupported(bytes32 ticker, bool isSupported) external {
        supported[ticker] = isSupported;
    }

    function verifyAt(bytes32, uint64 t, bytes calldata) external payable returns (uint256, uint64, bool) {
        return (1e18, t, false);
    }

    function verifyCloseAt(bytes32, uint64 t, bytes calldata)
        external
        payable
        returns (uint256, uint64, bool)
    {
        return (1e18, t, false);
    }

    function boundBps(bytes32) external pure returns (uint256) {
        return 60;
    }

    function multiplier(bytes32) external pure returns (uint256) {
        return 1e18;
    }
}
