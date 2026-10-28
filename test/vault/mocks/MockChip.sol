// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Plain ERC-20 with a public mint. `_fee` and `_afterTransfer` let the other mocks change behaviour.
contract MockChip {
    string public name;
    string public symbol;
    uint8 public immutable decimals;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);

    constructor(string memory name_, string memory symbol_, uint8 decimals_) {
        name = name_;
        symbol = symbol_;
        decimals = decimals_;
    }

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function burn(uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        totalSupply -= amount;
        emit Transfer(msg.sender, address(0), amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _move(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        _move(from, to, amount);
        return true;
    }

    function _move(address from, address to, uint256 amount) internal {
        uint256 fee = _fee(amount);
        balanceOf[from] -= amount;
        balanceOf[to] += amount - fee;
        totalSupply -= fee;
        emit Transfer(from, to, amount - fee);
        _afterTransfer(from, to, amount);
    }

    function _fee(uint256) internal view virtual returns (uint256) {
        return 0;
    }

    function _afterTransfer(address from, address to, uint256 amount) internal virtual {}
}

/// @notice A chip that burns 1% of every transfer: the receiver gets 99% of the amount sent. The tax can
///         be switched off and on, to model a coin that starts to tax after it was let in.
contract MockFeeChip is MockChip {
    /// @notice True while transfers are taxed (the default).
    bool public taxOn = true;

    constructor() MockChip("Taxed Chip", "TAX", 18) {}

    function setTax(bool on) external {
        taxOn = on;
    }

    function _fee(uint256 amount) internal view override returns (uint256) {
        return taxOn ? amount / 100 : 0;
    }
}

/// @notice A chip that calls back into a target during its next transfer, to test reentrancy.
contract ReentrantChip is MockChip {
    address public target;
    bytes public payload;
    bool public armed;
    bytes public lastRevert;
    bool public reentered;

    constructor() MockChip("Reentrant Chip", "REENT", 18) {}

    function arm(address target_, bytes calldata payload_) external {
        target = target_;
        payload = payload_;
        armed = true;
    }

    function _afterTransfer(address, address, uint256) internal override {
        if (!armed) return;
        armed = false;
        // Swallow the failure and remember it, so the outer call completes and the test can read it.
        (bool ok, bytes memory ret) = target.call(payload);
        lastRevert = ok ? bytes("") : ret;
        reentered = ok;
    }
}

/// @notice A chip whose decimals can be set to anything, for the ChipGuard decimals rule.
contract MockDecimalsChip {
    uint256 public decimals;

    constructor(uint256 decimals_) {
        decimals = decimals_;
    }
}

/// @notice Stand-in for the Doppler coin implementation: used behind minimal clones, so every coin shares
///         one code hash, and it has the launch balance limit switch.
contract MockDopplerCoin {
    bool public isBalanceLimitActive;

    function decimals() external pure returns (uint8) {
        return 18;
    }

    function setBalanceLimitActive(bool active) external {
        isBalanceLimitActive = active;
    }
}

/// @notice A coin that answers every call with a huge return blob and burns gas on unknown calls.
contract HostileChip {
    function decimals() external pure returns (uint8) {
        return 18;
    }

    fallback() external {
        assembly {
            return(0, 100000)
        }
    }
}
