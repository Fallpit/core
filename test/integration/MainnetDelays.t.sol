// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PitOracle} from "../../src/PitOracle.sol";
import {PitBook} from "../../src/hook/PitBook.sol";
import {IPitBook} from "../../src/hook/IPitBook.sol";
import {IPitOracle} from "../../src/interfaces/IPitOracle.sol";
import {IPyth} from "../../src/oracle/IPyth.sol";

/// @notice `OWNER_DELAY` and `SIGNER_DELAY` must be at least 24 hours on a mainnet chain id (Robinhood Chain
///         4663, Ethereum 1, Arbitrum One 42161, Base 8453): both constructors revert under that. The testnet
///         (46630) and anvil (31337) take any value.
contract MainnetDelaysTest is Test {
    IPyth internal pyth = IPyth(makeAddr("pyth"));
    address internal owner = makeAddr("owner");
    address[] internal noSigners;

    function _oracle(uint64 delay) internal returns (PitOracle) {
        return new PitOracle(pyth, owner, noSigners, 0, delay);
    }

    function test_mainnetRefusesShortDelays() public {
        PitOracle base = _oracle(24 hours);
        uint256[4] memory mainnets = [uint256(4663), 1, 42161, 8453];
        for (uint256 i; i < mainnets.length; ++i) {
            vm.chainId(mainnets[i]);
            vm.expectRevert(PitOracle.DelayTooShort.selector);
            _oracle(0);
            vm.expectRevert(PitOracle.DelayTooShort.selector);
            _oracle(24 hours - 1);
            assertEq(_oracle(24 hours).SIGNER_DELAY(), 24 hours);

            vm.expectRevert(IPitBook.DelayTooShort.selector);
            new PitBook(IPitOracle(address(base)), owner, 0);
            vm.expectRevert(IPitBook.DelayTooShort.selector);
            new PitBook(IPitOracle(address(base)), owner, 24 hours - 1);
            assertEq(new PitBook(IPitOracle(address(base)), owner, 24 hours).OWNER_DELAY(), 24 hours);
        }
        vm.chainId(31337);
    }

    function test_testnetsTakeAnyDelay() public {
        uint256[2] memory testnets = [uint256(46630), 31337];
        for (uint256 i; i < testnets.length; ++i) {
            vm.chainId(testnets[i]);
            PitOracle o = _oracle(0);
            assertEq(o.SIGNER_DELAY(), 0);
            assertEq(new PitBook(IPitOracle(address(o)), owner, 0).OWNER_DELAY(), 0);
        }
        vm.chainId(31337);
    }
}
