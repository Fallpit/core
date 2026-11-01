// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LadderMath} from "../../src/LadderMath.sol";
import {PitMath} from "../../src/hook/PitMath.sol";

/// @notice Settlement finds the close's band with `PitMath.bandOf`: it must equal the engine's `bandOf`
///         for every sigma and log return, at the grid's edges too.
contract PitMathBandTest is Test {
    LadderMath internal math;

    function setUp() public {
        math = new LadderMath();
    }

    function testFuzz_bandOf_matchesTheEngine(uint256 sigma, int256 x) public view {
        sigma = bound(sigma, 1, 1e18);
        x = bound(x, -1e36, 1e36);
        assertEq(PitMath.bandOf(sigma, x), math.bandOf(sigma, x));
    }

    function test_bandOf_atAndAroundEveryEdge() public view {
        uint256[3] memory sigmas = [uint256(0.035e18), 0.3e18, 7];
        for (uint256 k; k < 3; ++k) {
            uint256 sigma = sigmas[k];
            for (uint256 m; m < 39; ++m) {
                int256 e = PitMath.edge(sigma, m);
                assertEq(PitMath.bandOf(sigma, e), math.bandOf(sigma, e));
                assertEq(PitMath.bandOf(sigma, e - 1), math.bandOf(sigma, e - 1));
                assertEq(PitMath.bandOf(sigma, e + 1), math.bandOf(sigma, e + 1));
            }
        }
    }
}
