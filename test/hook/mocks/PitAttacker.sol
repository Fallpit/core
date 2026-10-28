// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FallpitRouter} from "../../../src/FallpitRouter.sol";
import {FallpitHook} from "../../../src/FallpitHook.sol";
import {ILadderMath} from "../../../src/interfaces/ILadderMath.sol";
import {MockLadderMath} from "./MockLadderMath.sol";

interface IERC20Like {
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address owner) external view returns (uint256);
}

/// @notice An attacker as a contract: it commits, fills its own commits with reports of its choosing,
///         refunds, redeems, and can do several of these atomically in one transaction. It pays the fill
///         fee of its commits from its own ETH (fund it at construction) and takes the fees it earns as a
///         filler.
contract PitAttacker {
    FallpitRouter public immutable router;
    FallpitHook public immutable hook;

    constructor(FallpitRouter router_, FallpitHook hook_) payable {
        router = router_;
        hook = hook_;
    }

    receive() external payable {}

    function approve(address token, address spender) external {
        IERC20Like(token).approve(spender, type(uint256).max);
    }

    /// @notice A ticket needs no approval (a sell escrows through `hook.pull`); a no-op, so the attacks
    ///         read the same for chips and tickets.
    function approve(uint256, address) external {}

    function commit(bytes32 roundId, uint8 index, bool isBuy, uint256 shares, uint256 limit)
        external
        returns (uint256)
    {
        uint256 fee = hook.getConfig(roundId).params.fillFee;
        return router.commit{value: fee}(roundId, index, isBuy, shares, limit);
    }

    function fill(uint256 id, bytes calldata report) external returns (bool) {
        return router.fill(id, report);
    }

    /// @notice Tries a list of reports for one commit and stops at the first that fills.
    function fillWithAny(uint256 id, bytes[] calldata reports) external returns (uint256 used) {
        for (uint256 i; i < reports.length; ++i) {
            try router.fill(id, reports[i]) returns (bool) {
                return i;
            } catch {}
        }
        return type(uint256).max;
    }

    function refund(uint256 id) external {
        router.refund(id);
    }

    function redeem(uint256 id, uint256 amount) external returns (uint256) {
        return router.redeem(id, amount);
    }

    function redeemDirect(uint256 id, uint256 amount) external returns (uint256) {
        return hook.redeem(id, address(this), amount);
    }

    /// @notice Redeems the same tickets twice in one transaction; the second call must fail.
    function redeemTwice(uint256 id, uint256 amount) external returns (uint256) {
        hook.redeem(id, address(this), amount);
        return hook.redeem(id, address(this), amount);
    }

    function send(address token, address to, uint256 amount) external {
        IERC20Like(token).transfer(to, amount);
    }

    /// @notice Sends tickets of `id` (an ERC-6909 transfer on the hook).
    function send(uint256 id, address to, uint256 amount) external {
        hook.transfer(to, id, amount);
    }
}

/// @notice A broken pricing engine that gives tokens away: buys cost nothing and sells pay one chip per
///         share. Used to show that the hook's own solvency check, not the math, is the last line.
contract GiveawayMath is MockLadderMath {
    function fill(
        int256[40] calldata v,
        uint256[40] calldata,
        uint256,
        Ctx calldata,
        uint8 lo,
        uint8 hi,
        int256 delta
    ) external pure override returns (Fill memory f) {
        f.v = v;
        for (uint8 j = lo; j <= hi; ++j) {
            f.v[j] += delta;
        }
        f.amount = delta > 0 ? 0 : uint256(-delta);
    }
}
