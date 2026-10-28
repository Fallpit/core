// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PitOracle} from "../../src/PitOracle.sol";

/// @notice Shared helpers for the PitOracle tests: a sorted keeper signer set and report builders.
abstract contract OracleTestBase is Test {
    bytes32 internal constant TSLA = bytes32("TSLA");

    /// @dev Private keys of the keeper signers, ordered so that their addresses ascend.
    uint256[] internal keys;
    address[] internal signerAddrs;

    /// @dev Creates `n` test signers sorted by address.
    function _makeSigners(uint256 n) internal {
        delete keys;
        delete signerAddrs;
        for (uint256 i; i < n; ++i) {
            (address a, uint256 k) = makeAddrAndKey(string.concat("keeper-signer-", vm.toString(i)));
            keys.push(k);
            signerAddrs.push(a);
        }
        for (uint256 i = 1; i < n; ++i) {
            for (uint256 j = i; j > 0 && signerAddrs[j - 1] > signerAddrs[j]; --j) {
                (signerAddrs[j - 1], signerAddrs[j]) = (signerAddrs[j], signerAddrs[j - 1]);
                (keys[j - 1], keys[j]) = (keys[j], keys[j - 1]);
            }
        }
    }

    /// @dev 65-byte `r || s || v` signature of `p` by `key`, for oracle `o` on the current chain.
    function _sign(PitOracle o, uint256 key, PitOracle.Print memory p) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, o.printDigest(p));
        return abi.encodePacked(r, s, v);
    }

    /// @dev Source 0x02 report from ready signatures.
    function _report(PitOracle.Print memory p, bytes[] memory sigs) internal pure returns (bytes memory) {
        return abi.encodePacked(uint8(0x02), abi.encode(p, sigs));
    }

    /// @dev Source 0x02 report signed by signers `a` and `b` (indexes into the sorted set).
    function _report2(PitOracle o, PitOracle.Print memory p, uint256 a, uint256 b)
        internal
        view
        returns (bytes memory)
    {
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _sign(o, keys[a], p);
        sigs[1] = _sign(o, keys[b], p);
        return _report(p, sigs);
    }

    /// @dev Source 0x01 report from an update blob.
    function _pythReport(bytes memory blob) internal pure returns (bytes memory) {
        return abi.encodePacked(uint8(0x01), blob);
    }
}
