// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console} from "forge-std/Test.sol";
import {StackFixture} from "./StackFixture.sol";
import {PitVault} from "../../src/PitVault.sol";

/// @notice Profits and losses of a house are shared pro rata to capital at lock time, the endowment included.
///         An LP who also bets against its own house gets no edge from the endowment: the bet keeps a
///         negative expected value.
contract EndowmentDrainTest is StackFixture {
    address internal community = makeAddr("community");
    address internal eve = makeAddr("eve");

    uint256 internal constant ENDOWMENT = 100_000e18;
    uint256 internal constant EVE_LP = 900_000e18;
    uint256 internal constant SHARES = 200_000e18; // ten fills at the 2% cap

    /// @dev Chips in the wallet plus the value of the vault position.
    function _wealth(address who) internal view returns (uint256) {
        (uint256 shares,,, uint256 claimable) = vault.positionOf(house, who);
        return chip.balanceOf(who) + vault.convertToAssets(house, shares) + claimable;
    }

    function test_endowment_lpBettingAgainstOwnHouse_hasNegativeExpectedValue() public {
        // A community donated 100,000 chips (for example through CommunityTreasury.harvest).
        _donate(community, ENDOWMENT);
        // Eve brings 90% of the house's capital as an ordinary LP and keeps chips to trade with.
        _lpDeposit(eve, EVE_LP);
        _fund(eve, 1_000_000e18);
        uint256 start = _wealth(eve);

        _open(60);
        // Eve buys 200,000 HIGHER at the previous close, at the open, with the stock unchanged.
        (,, uint256 pBefore,,,) = lens.quote(roundId, HIGHER, true, 20_000e18, S0, clock + 2);
        uint256 paid;
        for (uint256 i; i < 10; ++i) {
            paid += _buy(eve, HIGHER, 20_000e18, S0);
        }
        uint256 snap = vm.snapshotState();

        // Branch A: HIGHER wins. The house's loss is shared 9 : 1 by eve's shares and the endowment.
        _closeAndFinalize(S0 * 101 / 100);
        uint256 higher = _token(HIGHER).id;
        vm.prank(eve);
        router.redeem(higher, SHARES);
        PitVault.House memory h = vault.getHouse(house);
        uint256 winGain = _wealth(eve) - start;
        uint256 houseLoss = EVE_LP + ENDOWMENT - (h.lpAssets + h.endowment);
        assertApproxEqAbs(
            EVE_LP - h.lpAssets, houseLoss * 9 / 10, 2, "the shares took nine tenths of the loss"
        );
        assertApproxEqAbs(
            ENDOWMENT - h.endowment, houseLoss / 10, 2, "the endowment one tenth, not all of it"
        );
        console.log(
            "HIGHER wins : eve +%s, endowment %s -> %s", winGain / 1e18, ENDOWMENT / 1e18, h.endowment / 1e18
        );

        // Branch B: HIGHER loses.
        vm.revertToState(snap);
        _closeAndFinalize(S0 * 99 / 100);
        h = vault.getHouse(house);
        uint256 loseLoss = start - _wealth(eve);
        console.log(
            "HIGHER loses: eve -%s, endowment %s -> %s", loseLoss / 1e18, ENDOWMENT / 1e18, h.endowment / 1e18
        );
        console.log("paid for the bet: %s, house's own probability of HIGHER: %s (WAD)", paid / 1e18, pBefore);

        // The same bet without the LP stake: win 200,000 - paid, lose paid. Negative expected value
        // under the house's own probability, as it should be.
        uint256 p = pBefore;
        assertLt((SHARES - paid) * p, paid * (1e18 - p), "plain trader: negative expected value");
        // With the LP stake it is negative as well: what eve wins as a trader she mostly loses as an LP,
        // and the endowment only ever carries its own tenth.
        assertLt(winGain * p, loseLoss * (1e18 - p), "LP who trades: negative expected value too");
        uint256 cost = (loseLoss * (1e18 - p) - winGain * p) / 1e18;
        console.log("expected value of the round for eve: -%s chips", cost / 1e18);
        // her win is a tenth of the plain trader's win: the rest she paid to herself
        assertLt(winGain, (SHARES - paid) * 12 / 100);
    }
}
