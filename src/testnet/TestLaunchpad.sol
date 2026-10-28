// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {FaucetCoin} from "./FaucetCoin.sol";

/// @title TestLaunchpad
/// @notice Testnet only: a stand-in launchpad for open listing. Anyone
///         launches a faucet coin against an anchor (a mirror stock token, or address(0) for ETH), and the
///         launch record answers `getLaunchedToken` in the Pons v2 shape: word 0 is the coin itself, word 4
///         the anchor. The deployment reads it with `LaunchRecordSource(this, getLaunchedToken, 0, Self, 4)`
///         and trusts it in ChipGuard (`ReturnsChip`), as mainnet does Pons v2.
contract TestLaunchpad {
    struct Launch {
        address token;
        address creator;
        uint64 launchedAt;
        uint256 supply;
        address anchor;
    }

    mapping(address => Launch) internal _launches;
    address[] public tokens;

    event Launched(
        address indexed token, address indexed anchor, address indexed creator, string symbol, uint256 supply
    );

    error ZeroSupply();

    /// @notice Launches a coin against `anchor` and sends its whole supply to the caller.
    function launch(string calldata name, string calldata symbol, uint256 supply, address anchor)
        external
        returns (address token)
    {
        if (supply == 0) revert ZeroSupply();
        FaucetCoin coin = new FaucetCoin(name, symbol, supply);
        token = address(coin);
        _launches[token] = Launch(token, msg.sender, uint64(block.timestamp), supply, anchor);
        tokens.push(token);
        coin.transfer(msg.sender, supply);
        emit Launched(token, anchor, msg.sender, symbol, supply);
    }

    /// @notice The launch record of `token` (all zero when this launchpad did not launch it).
    function getLaunchedToken(address token)
        external
        view
        returns (address token_, address creator, uint64 launchedAt, uint256 supply, address anchor)
    {
        Launch memory l = _launches[token];
        return (l.token, l.creator, l.launchedAt, l.supply, l.anchor);
    }

    function tokenCount() external view returns (uint256) {
        return tokens.length;
    }
}
