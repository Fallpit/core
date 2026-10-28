// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {ERC20} from "solady/tokens/ERC20.sol";

/// @title FaucetCoin
/// @notice Testnet chip: a plain 18-decimal ERC-20 with a public faucet. Play money only.
/// @dev Three rules, all fixed at deployment:
///      - `faucet()` mints 1,000 coins to the caller, once per address per 24 hours;
///      - a holder can burn only its own balance (there is no `burn(from, amount)`);
///      - nobody can mint otherwise: the only other supply is the amount minted to the deployer in the
///        constructor. There is no owner.
contract FaucetCoin is ERC20 {
    /// @notice Coins one faucet call mints.
    uint256 public constant FAUCET_AMOUNT = 1_000e18;
    /// @notice Seconds an address waits between two faucet calls.
    uint256 public constant FAUCET_INTERVAL = 24 hours;

    string internal _name;
    string internal _symbol;

    /// @notice When `account` may use the faucet next (zero: now).
    mapping(address account => uint256) public nextFaucetAt;

    event Faucet(address indexed account, uint256 amount);

    error FaucetNotReady(uint256 availableAt);

    /// @param initialSupply coins minted once to the deployer (for seeding houses and pools)
    constructor(string memory name_, string memory symbol_, uint256 initialSupply) {
        _name = name_;
        _symbol = symbol_;
        if (initialSupply != 0) _mint(msg.sender, initialSupply);
    }

    /// @notice Mints `FAUCET_AMOUNT` to the caller. Each address may call once per `FAUCET_INTERVAL`.
    function faucet() external {
        uint256 availableAt = nextFaucetAt[msg.sender];
        if (block.timestamp < availableAt) revert FaucetNotReady(availableAt);
        nextFaucetAt[msg.sender] = block.timestamp + FAUCET_INTERVAL;
        _mint(msg.sender, FAUCET_AMOUNT);
        emit Faucet(msg.sender, FAUCET_AMOUNT);
    }

    /// @notice Burns `amount` of the caller's own coins.
    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }

    function name() public view override returns (string memory) {
        return _name;
    }

    function symbol() public view override returns (string memory) {
        return _symbol;
    }

    /// @dev No implicit allowances: only explicit approvals move a holder's coins.
    function _givePermit2InfiniteAllowance() internal pure override returns (bool) {
        return false;
    }
}
