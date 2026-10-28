// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ILadderMath} from "../../src/interfaces/ILadderMath.sol";
import {LadderMathBase} from "./LadderMathBase.sol";

/// @notice Gas of `fill`. The spec's ceiling is 5M per fill. The named tests feed the committed snapshot
///         (test/math/.gas-snapshot, made with `forge snapshot --match-contract LadderMathGasTest --snap
///         test/math/.gas-snapshot`); the fuzz test asserts the ceiling over the whole domain.
/// @dev Gas is measured around the external call, so it includes the ABI encoding of the 80 words of state
///      and depths and the decoding of the result, as the hook will pay them.
contract LadderMathGasTest is LadderMathBase {
    uint256 internal constant GAS_CEILING = 5_000_000;
    uint256 internal constant SIGMA = 0.035e18;

    uint256[40] internal b0;
    int256[40] internal busy;

    function setUp() public override {
        super.setUp();
        b0 = math.openDepths(SIGMA, 20_000e18, 0.3e18);
        // A state after a morning of trading on the six strike tokens.
        int256[40] memory v;
        ILadderMath.Ctx memory ctx = _ctx(0.004e18, 0.03e18, WAD, WAD);
        v = math.fill(v, b0, SIGMA, ctx, 20, 39, 900e18).v;
        v = math.fill(v, b0, SIGMA, ctx, 0, 15, 300e18).v;
        v = math.fill(v, b0, SIGMA, ctx, 24, 39, 1500e18).v;
        v = math.fill(v, b0, SIGMA, ctx, 0, 23, 700e18).v;
        v = math.fill(v, b0, SIGMA, ctx, 16, 39, 250e18).v;
        busy = v;
    }

    function _measure(int256[40] memory v, ILadderMath.Ctx memory ctx, uint8 lo, uint8 hi, int256 delta)
        internal
        view
        returns (uint256 used)
    {
        uint256[40] memory depths = b0;
        uint256 start = gasleft();
        math.fill(v, depths, SIGMA, ctx, lo, hi, delta);
        used = start - gasleft();
        assertLt(used, GAS_CEILING);
    }

    /// @dev First trade of the day: empty state, no depth decay.
    function test_gas_fill_firstTrade() public {
        int256[40] memory v;
        emit log_named_uint("fill gas", _measure(v, _ctx(0.001e18, 0.034e18, WAD, WAD), 20, 39, 100e18));
    }

    /// @dev Mid-session buy on a busy book, same depth scale as the last fill.
    function test_gas_fill_buyNoRescale() public {
        emit log_named_uint("fill gas", _measure(busy, _ctx(-0.006e18, 0.025e18, WAD, WAD), 24, 39, 120e18));
    }

    /// @dev Mid-session buy with depth decay since the last fill (the usual case: three lambda solves).
    function test_gas_fill_buyWithRescale() public {
        emit log_named_uint(
            "fill gas", _measure(busy, _ctx(-0.006e18, 0.025e18, WAD, 0.82e18), 24, 39, 120e18)
        );
    }

    /// @dev Sell near the cutoff: small sd, depth at its floor.
    function test_gas_fill_sellNearCutoff() public {
        emit log_named_uint(
            "fill gas", _measure(busy, _ctx(0.011e18, 0.004e18, 0.45e18, 0.3e18), 0, 23, -400e18)
        );
    }

    /// @dev sd = 1.5 sigma puts all 39 edges inside |z| < 9, the slowest case of the normal CDF.
    function test_gas_fill_widePrior() public {
        emit log_named_uint("fill gas", _measure(busy, _ctx(0.02e18, 0.0525e18, WAD, 0.7e18), 5, 30, 2000e18));
    }

    /// @dev Gas of one fill with a rescale and a trade of up to the capital, somewhere in the fuzz domain.
    ///      External so that each scenario's memory is released.
    function scenarioFillGas(uint256 seed) external view returns (uint256 used) {
        Scn memory s = _scenario(seed);
        (uint8 lo, uint8 hi) = _set(seed, 21);
        int256 delta = int256(_size(seed, 22, s.capital));
        if (_rand(seed, 23) % 2 == 0) delta = -delta;
        ILadderMath.Ctx memory ctx = _ctx(s.x, s.sd, s.g, bound(_rand(seed, 24), 0.3e18, s.g));
        uint256 start = gasleft();
        math.fill(s.v, s.b0, s.sigma, ctx, lo, hi, delta);
        used = start - gasleft();
    }

    /// @dev The ceiling over the whole fuzz domain.
    function testFuzz_gas_fill_underCeiling(uint256 seed) public view {
        assertLt(this.scenarioFillGas(seed), GAS_CEILING);
    }

    /// @dev Largest and mean fill gas over 120 fixed scenarios of the fuzz domain.
    function test_gas_fill_worstOverScenarios() public {
        uint256 worst;
        uint256 total;
        uint256 n = 120;
        for (uint256 seed = 1; seed <= n; ++seed) {
            uint256 used = this.scenarioFillGas(seed);
            total += used;
            if (used > worst) worst = used;
        }
        emit log_named_uint("fill gas, worst of 120 scenarios", worst);
        emit log_named_uint("fill gas, mean of 120 scenarios", total / n);
        assertLt(worst, GAS_CEILING);
    }
}
