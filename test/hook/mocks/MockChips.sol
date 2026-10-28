// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "solady/tokens/ERC20.sol";

/// @notice Plain ERC-20 chip with a public mint.
contract MockChip is ERC20 {
    uint8 private immutable _decimals;

    constructor(uint8 decimals_) {
        _decimals = decimals_;
    }

    function name() public pure override returns (string memory) {
        return "Mock Chip";
    }

    function symbol() public pure override returns (string memory) {
        return "CHIP";
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _givePermit2InfiniteAllowance() internal pure override returns (bool) {
        return false;
    }
}

/// @notice Chip that burns 1% of every transfer (rounded down): the receiver gets less than was sent.
///         The tax can be switched off and on, to model a coin that starts to tax after it was let in.
contract MockFeeChip is MockChip(18) {
    /// @notice Total burned by the transfer tax.
    uint256 public taxed;
    /// @notice True while transfers are taxed (the default).
    bool public taxOn = true;

    function setTax(bool on) external {
        taxOn = on;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        uint256 tax = taxOn ? amount / 100 : 0;
        _burn(msg.sender, tax);
        taxed += tax;
        return super.transfer(to, amount - tax);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        uint256 tax = taxOn ? amount / 100 : 0;
        _spendAllowance(from, msg.sender, tax);
        _burn(from, tax);
        taxed += tax;
        return super.transferFrom(from, to, amount - tax);
    }
}

/// @notice Malicious chip: on every transfer it calls `target` with `data` (a reentrancy attempt) and
///         records whether the call got through. It never reverts the transfer itself.
contract ReentrantChip is MockChip(18) {
    address public target;
    bytes public data;
    uint256 public attempts;
    uint256 public successes;
    bytes public lastRevert;

    function arm(address target_, bytes calldata data_) external {
        target = target_;
        data = data_;
    }

    function disarm() external {
        target = address(0);
    }

    function _afterTokenTransfer(address, address, uint256) internal override {
        address target_ = target;
        if (target_ == address(0)) return;
        target = address(0); // no recursion through the attack itself
        (bool ok, bytes memory ret) = target_.call(data);
        attempts++;
        if (ok) successes++;
        else lastRevert = ret;
        target = target_;
    }
}
