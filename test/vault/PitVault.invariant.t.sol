// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

import {PitVault} from "../../src/PitVault.sol";
import {ITickerGate} from "../../src/interfaces/IPitVault.sol";
import {ChipGuard} from "../../src/ChipGuard.sol";
import {IPitVault} from "../../src/interfaces/IPitVault.sol";
import {MockChip, MockFeeChip} from "./mocks/MockChip.sol";
import {MockHook, MockOracle} from "./mocks/MockHook.sol";

/// @notice Drives the vault with random LP actions and random round results over four houses on two chips:
///         one plain, and one that the run switches between plain and a 1% transfer tax (a coin that
///         starts to tax after it was let in). While the tax is on, every deposit and donation of that
///         chip must be refused and every outflow delivers the nominal amount less the tax; the books
///         must hold either way. It never guards a vault call with try/catch except where a revert is the
///         specified answer, and the invariant run fails on any revert, so a bricked function fails the
///         test.
contract VaultHandler is Test {
    uint256 internal constant V = 1e6;
    uint256 internal constant MAX_SHARES_PER_ASSET = 1e18;
    uint256 internal constant MAX_AMOUNT = 1e24;

    PitVault public vault;
    MockHook public hook;
    MockFeeChip public taxChip;
    bytes32[] public houses;
    address[] public actors;

    struct Snap {
        uint256 lp;
        uint256 endowment;
        uint256 shares;
    }

    mapping(bytes32 => Snap) public snaps; // house state when its capital was pulled
    mapping(bytes32 => uint256) public hookHolds; // chips the hook received for the running round

    uint256 public violations;
    string public lastViolation;
    uint256 public rounds;
    uint256 public zeroReturns;
    uint256 public wipeouts;
    uint256 public queuedDeposits;
    uint256 public queuedWithdrawals;
    uint256 public claims;
    uint256 public refusedInflows;
    uint256 public taxedReturns;

    constructor(
        PitVault vault_,
        MockHook hook_,
        MockFeeChip taxChip_,
        bytes32[] memory houses_,
        address[] memory actors_
    ) {
        vault = vault_;
        hook = hook_;
        taxChip = taxChip_;
        houses = houses_;
        actors = actors_;
    }

    /// @dev Outside `finish`, no house's endowment may ever go down: nothing can withdraw it.
    modifier endowmentOnlyGrows() {
        uint256 n = houses.length;
        uint256[] memory beforeE = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            beforeE[i] = vault.getHouse(houses[i]).endowment;
        }
        _;
        for (uint256 i; i < n; ++i) {
            if (vault.getHouse(houses[i]).endowment < beforeE[i]) {
                _violate("endowment fell outside a round result");
            }
        }
    }

    // ---------------------------------------------------------------------------------------------
    // LP actions
    // ---------------------------------------------------------------------------------------------

    function deposit(uint256 actorSeed, uint256 houseSeed, uint256 amount) external endowmentOnlyGrows {
        (bytes32 h, address actor, MockChip c) = _pick(actorSeed, houseSeed);
        amount = bound(amount, 1, MAX_AMOUNT);
        _fund(c, actor, amount);
        if (!vault.isLocked(h)) vault.processQueues(h);
        PitVault.House memory a = vault.getHouse(h);
        if (_tax(c, amount) != 0) {
            _refusedInflow(h, actor, c, amount, true);
            return;
        }

        vm.prank(actor);
        try vault.deposit(h, amount) returns (uint256 shares) {
            PitVault.House memory b = vault.getHouse(h);
            if (a.locked) {
                ++queuedDeposits;
                if (shares != 0) _violate("queued deposit minted");
                _assertFrozen(a, b);
            } else {
                if (shares == 0) _violate("deposit minted nothing");
                _assertPriceHeld(a, b);
            }
        } catch (bytes memory err) {
            // The only acceptable failure: a deposit too small to mint one share at a high price.
            if (a.locked || bytes4(err) != PitVault.ZeroShares.selector) _violate("deposit reverted");
        }
    }

    function requestWithdraw(uint256 actorSeed, uint256 houseSeed, uint256 bps) external endowmentOnlyGrows {
        (bytes32 h, address actor, MockChip c) = _pick(actorSeed, houseSeed);
        // Take the first actor from the seed on that has shares.
        uint256 shares;
        for (uint256 i; i < actors.length && shares == 0; ++i) {
            actor = actors[(actorSeed % actors.length + i) % actors.length];
            vault.settle(h, actor);
            shares = vault.balanceOf(actor, uint256(h)) * bound(bps, 1, 10_000) / 10_000;
        }
        if (shares == 0) return;
        PitVault.House memory a = vault.getHouse(h);
        uint256 worth = vault.convertToAssets(h, shares);
        uint256 balanceBefore = c.balanceOf(actor);

        vm.prank(actor);
        uint256 assets = vault.requestWithdraw(h, shares);

        PitVault.House memory b = vault.getHouse(h);
        if (a.locked) {
            ++queuedWithdrawals;
            if (assets != 0 || c.balanceOf(actor) != balanceBefore) _violate("queued withdrawal paid");
            _assertFrozen(a, b);
        } else {
            if (assets != worth) _violate("withdrawal paid a different price");
            if (c.balanceOf(actor) - balanceBefore != assets - _tax(c, assets)) {
                _violate("withdrawal payout");
            }
            _assertPriceHeld(a, b);
        }
    }

    function claim(uint256 actorSeed, uint256 houseSeed) external endowmentOnlyGrows {
        (bytes32 h, address actor, MockChip c) = _pick(actorSeed, houseSeed);
        uint256 claimable;
        for (uint256 i; i < actors.length && claimable == 0; ++i) {
            actor = actors[(actorSeed % actors.length + i) % actors.length];
            vault.settle(h, actor);
            (,,, claimable) = vault.positionOf(h, actor);
        }
        if (claimable == 0) return;
        uint256 balanceBefore = c.balanceOf(actor);
        vm.prank(actor);
        uint256 paid = vault.claim(h);
        ++claims;
        if (paid != claimable) _violate("claim paid a different amount");
        if (c.balanceOf(actor) - balanceBefore != paid - _tax(c, paid)) _violate("claim payout");
    }

    function cancelDeposit(uint256 actorSeed, uint256 houseSeed) external endowmentOnlyGrows {
        (bytes32 h, address actor, MockChip c) = _pick(actorSeed, houseSeed);
        if (!vault.isLocked(h)) return;
        uint256 queued;
        for (uint256 i; i < actors.length && queued == 0; ++i) {
            actor = actors[(actorSeed % actors.length + i) % actors.length];
            (, queued,,) = vault.positionOf(h, actor);
        }
        if (queued == 0) return;
        PitVault.House memory a = vault.getHouse(h);
        uint256 balanceBefore = c.balanceOf(actor);
        vm.prank(actor);
        uint256 back = vault.cancelDeposit(h);
        if (back != queued) _violate("cancel returned a different amount");
        if (c.balanceOf(actor) - balanceBefore != back - _tax(c, back)) _violate("cancel payout");
        _assertFrozen(a, vault.getHouse(h));
    }

    function donate(uint256 actorSeed, uint256 houseSeed, uint256 amount) external endowmentOnlyGrows {
        (bytes32 h, address actor, MockChip c) = _pick(actorSeed, houseSeed);
        amount = bound(amount, 1, MAX_AMOUNT);
        _fund(c, actor, amount);
        PitVault.House memory a = vault.getHouse(h);
        if (_tax(c, amount) != 0) {
            _refusedInflow(h, actor, c, amount, false);
            return;
        }
        vm.prank(actor);
        uint256 credited = vault.donate(h, amount);
        PitVault.House memory b = vault.getHouse(h);
        if (credited != amount) _violate("donation credit");
        if (b.lpAssets != a.lpAssets || b.totalShares != a.totalShares) {
            _violate("donation moved the share price");
        }
        if (a.locked) _assertFrozen(a, b);
        else if (b.endowment != a.endowment + credited) _violate("donation not in endowment");
    }

    function transferShares(uint256 fromSeed, uint256 toSeed, uint256 houseSeed, uint256 bps)
        external
        endowmentOnlyGrows
    {
        (bytes32 h, address from,) = _pick(fromSeed, houseSeed);
        address to = actors[toSeed % actors.length];
        vault.settle(h, from);
        uint256 shares = vault.balanceOf(from, uint256(h)) * bound(bps, 1, 10_000) / 10_000;
        if (shares == 0 || from == to) return;
        PitVault.House memory a = vault.getHouse(h);
        vm.prank(from);
        vault.transfer(to, uint256(h), shares);
        PitVault.House memory b = vault.getHouse(h);
        if (b.lpAssets != a.lpAssets || b.totalShares != a.totalShares) {
            _violate("transfer moved the share price");
        }
    }

    function processQueues(uint256 houseSeed) external endowmentOnlyGrows {
        bytes32 h = houses[houseSeed % houses.length];
        if (vault.isLocked(h)) return;
        vault.processQueues(h);
    }

    function settle(uint256 actorSeed, uint256 houseSeed) external endowmentOnlyGrows {
        (bytes32 h, address actor,) = _pick(actorSeed, houseSeed);
        vault.settle(h, actor);
    }

    /// @dev The second chip starts or stops taxing its transfers.
    function toggleTax(bool on) external endowmentOnlyGrows {
        taxChip.setTax(on);
    }

    /// @dev Chips sent straight to the vault, outside any vault call.
    function stray(uint256 houseSeed, uint256 amount) external endowmentOnlyGrows {
        bytes32 h = houses[houseSeed % houses.length];
        MockChip c = MockChip(vault.chipOf(h));
        c.mint(address(vault), bound(amount, 1, 1e20));
    }

    // ---------------------------------------------------------------------------------------------
    // Rounds
    // ---------------------------------------------------------------------------------------------

    /// @dev Moves the house's round forward: starts one when it is home, ends it when it is out.
    function pull(uint256 houseSeed, uint256 mode, uint256 x) external {
        bytes32 h = houses[houseSeed % houses.length];
        if (vault.isLocked(h)) _finishRound(h, mode, x);
        else _pullRound(h);
    }

    /// @dev Same as `pull`, so rounds turn over twice as often.
    function finish(uint256 houseSeed, uint256 mode, uint256 x) external {
        bytes32 h = houses[houseSeed % houses.length];
        if (vault.isLocked(h)) _finishRound(h, mode, x);
        else _pullRound(h);
    }

    function _pullRound(bytes32 h) internal endowmentOnlyGrows {
        MockChip c = MockChip(vault.chipOf(h));
        uint256 expected = vault.roundCapital(h);
        uint256 hookBefore = c.balanceOf(address(hook));
        uint256 sent = hook.pull(h);
        if (sent != expected) _violate("pull sent a different capital than roundCapital");
        PitVault.House memory s = vault.getHouse(h);
        if (sent != s.lpAssets + s.endowment) _violate("pull did not send the whole capital");
        hookHolds[h] = c.balanceOf(address(hook)) - hookBefore;
        snaps[h] = Snap(s.lpAssets, s.endowment, s.totalShares);
        ++rounds;
    }

    function _finishRound(bytes32 h, uint256 mode, uint256 x) internal {
        PitVault.House memory s = vault.getHouse(h);
        Snap memory snap = snaps[h];
        // Nothing done during the round may change who owns its result.
        if (s.lpAssets != snap.lp || s.endowment != snap.endowment || s.totalShares != snap.shares) {
            _violate("capital or shares changed while locked");
        }

        MockChip c = MockChip(s.chip);
        uint256 holds = hookHolds[h];
        uint256 back;
        mode = mode % 6;
        if (mode == 0) back = 0; // total loss
        else if (mode == 1) back = holds; // flat
        else if (mode == 2) back = holds + bound(x, 1, (holds < MAX_AMOUNT ? holds : MAX_AMOUNT) + 1); // win
        else if (mode == 3) back = bound(x, 0, holds); // any loss
        else if (mode == 4) back = bound(x, 0, 1e6); // dust
        else back = holds - holds / 20; // small loss
        if (back > holds) {
            c.mint(address(hook), back - holds);
        } else if (holds > back) {
            vm.prank(address(hook));
            c.burn(holds - back);
        }
        hookHolds[h] = 0;
        uint256 received = hook.giveBack(h, address(c), back);
        if (received == 0) ++zeroReturns;
        if (_tax(c, back) != 0) ++taxedReturns;

        // The waterfall, restated: profits and losses are both split pro rata to capital at lock.
        uint256 lp = s.sent == 0 ? 0 : FixedPointMathLib.fullMulDiv(received, snap.lp, s.sent);
        uint256 e = received - lp;
        if (received < s.sent && snap.endowment != 0 && snap.lp != 0 && e > snap.endowment) {
            _violate("the endowment grew on a loss");
        }
        if (lp != 0 && (snap.shares == 0 || snap.shares / MAX_SHARES_PER_ASSET > lp)) {
            e += lp;
            lp = 0;
            ++wipeouts;
        }
        e += s.pendingDonations;

        PitVault.House memory b = vault.getHouse(h);
        if (b.locked) _violate("still locked after return");
        if (b.lpAssets != lp || b.endowment != e) _violate("waterfall result");
        if (b.totalShares != snap.shares) _violate("return changed the share supply");
        if (b.pendingDeposits != s.pendingDeposits || b.pendingShares != s.pendingShares) {
            _violate("return touched the queues");
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------------------------

    function housesLength() external view returns (uint256) {
        return houses.length;
    }

    function actorsLength() external view returns (uint256) {
        return actors.length;
    }

    function _pick(uint256 actorSeed, uint256 houseSeed)
        internal
        view
        returns (bytes32 h, address actor, MockChip c)
    {
        h = houses[houseSeed % houses.length];
        actor = actors[actorSeed % actors.length];
        c = MockChip(vault.chipOf(h));
    }

    function _fund(MockChip c, address actor, uint256 amount) internal {
        c.mint(actor, amount);
        vm.prank(actor);
        c.approve(address(vault), type(uint256).max);
    }

    /// @dev What the second chip keeps of a transfer while its tax is on; zero otherwise and for the plain
    ///      chip.
    function _tax(MockChip c, uint256 amount) internal view returns (uint256) {
        return address(c) == address(taxChip) && taxChip.taxOn() ? amount / 100 : 0;
    }

    /// @dev A deposit or donation of a chip that taxes the transfer: the vault must refuse it with
    ///      `InexactTransfer` and change nothing.
    function _refusedInflow(bytes32 h, address actor, MockChip c, uint256 amount, bool isDeposit) internal {
        PitVault.House memory a = vault.getHouse(h);
        uint256 booked = vault.accounted(address(c));
        uint256 balance = c.balanceOf(address(vault));
        vm.prank(actor);
        (bool ok, bytes memory err) = address(vault)
            .call(
                abi.encodeWithSelector(isDeposit ? vault.deposit.selector : vault.donate.selector, h, amount)
            );
        if (ok || bytes4(err) != PitVault.InexactTransfer.selector) {
            _violate("a taxed inflow was not refused");
        }
        PitVault.House memory b = vault.getHouse(h);
        if (
            keccak256(abi.encode(a)) != keccak256(abi.encode(b)) || vault.accounted(address(c)) != booked
                || c.balanceOf(address(vault)) != balance
        ) _violate("a refused inflow changed the vault");
        ++refusedInflows;
    }

    /// @dev While locked, nothing an LP does may change the capital or the share supply of the round.
    function _assertFrozen(PitVault.House memory a, PitVault.House memory b) internal {
        if (b.lpAssets != a.lpAssets || b.endowment != a.endowment || b.totalShares != a.totalShares) {
            _violate("locked house changed");
        }
    }

    /// @dev price = (lpAssets + 1) / (totalShares + 1e6). A deposit or a withdrawal alone never lowers it
    ///      and raises it by rounding dust at most. A house with no capital behind its shares has no price
    ///      to hold: its shares are void once new capital arrives.
    function _assertPriceHeld(PitVault.House memory a, PitVault.House memory b) internal {
        if (b.endowment != a.endowment) _violate("deposit or withdrawal moved the endowment");
        if (a.lpAssets == 0 && a.totalShares != 0) return;
        uint256 left = (b.lpAssets + 1) * (a.totalShares + V);
        uint256 right = (a.lpAssets + 1) * (b.totalShares + V);
        if (left < right) {
            _violate("share price fell from a deposit or withdrawal");
            return;
        }
        uint256 slack = a.lpAssets + 1 > a.totalShares + V ? a.lpAssets + 1 : a.totalShares + V;
        if (left - right > slack) _violate("share price rose from a deposit or withdrawal");
    }

    function _violate(string memory what) internal {
        ++violations;
        lastViolation = what;
    }
}

contract PitVaultInvariantTest is Test {
    PitVault internal vault;
    MockHook internal hook;
    MockChip internal chip;
    MockFeeChip internal taxChip;
    VaultHandler internal handler;
    bytes32[] internal houses;
    address[] internal actors;

    function setUp() public {
        hook = new MockHook();
        ChipGuard guard = new ChipGuard(address(this));
        MockOracle oracle = new MockOracle();
        vault = new PitVault(address(hook), guard, ITickerGate(address(oracle)));
        vault.setLister(address(this));
        hook.setVault(IPitVault(address(vault)));
        chip = new MockChip("Chip", "CHIP", 18);
        taxChip = new MockFeeChip();
        taxChip.setTax(false); // the run switches it on and off
        guard.approve(address(chip), true);
        guard.approve(address(taxChip), true);
        oracle.setSupported(bytes32("NVDA"), true);
        oracle.setSupported(bytes32("TSLA"), true);

        houses.push(vault.createHouse(bytes32("NVDA"), address(chip)));
        houses.push(vault.createHouse(bytes32("TSLA"), address(chip)));
        houses.push(vault.createHouse(bytes32("NVDA"), address(taxChip)));
        houses.push(vault.createHouse(bytes32("TSLA"), address(taxChip)));
        for (uint256 i; i < 4; ++i) {
            actors.push(makeAddr(string(abi.encodePacked("actor", vm.toString(i)))));
        }

        handler = new VaultHandler(vault, hook, taxChip, houses, actors);
        targetContract(address(handler));
    }

    /// @dev For every chip: what the houses hold here (capital at home, queued deposits and donations, and
    ///      claimable withdrawals) is exactly what the vault booked, and never more than its balance.
    /// forge-config: default.invariant.fail-on-revert = true
    /// forge-config: default.invariant.depth = 250
    function invariant_claimsNeverExceedBalance() public view {
        uint256 plain = vault.heldFor(houses[0]) + vault.heldFor(houses[1]);
        uint256 taxed = vault.heldFor(houses[2]) + vault.heldFor(houses[3]);
        assertEq(plain, vault.accounted(address(chip)), "plain chip: house books != chip books");
        assertEq(taxed, vault.accounted(address(taxChip)), "tax chip: house books != chip books");
        assertLe(plain, chip.balanceOf(address(vault)), "plain chip: claims exceed balance");
        assertLe(taxed, taxChip.balanceOf(address(vault)), "tax chip: claims exceed balance");
    }

    /// @dev Everything the handler checks in line: the share price is unmoved by deposits and withdrawals,
    ///      a locked house's capital and shares are frozen (so just-in-time deposits and withdrawals cannot
    ///      capture or dodge its result), the waterfall, the endowment never falls outside a round result,
    ///      payouts match the books.
    /// forge-config: default.invariant.fail-on-revert = true
    /// forge-config: default.invariant.depth = 250
    function invariant_noHandlerViolation() public view {
        assertEq(handler.violations(), 0, handler.lastViolation());
    }

    /// @dev The ledger adds up: LP balances plus what the vault holds in the queues is the whole supply,
    ///      and what LPs can claim is covered by what is set aside.
    /// forge-config: default.invariant.fail-on-revert = true
    /// forge-config: default.invariant.depth = 250
    function invariant_ledgerAddsUp() public view {
        for (uint256 i; i < houses.length; ++i) {
            bytes32 h = houses[i];
            uint256 sum = vault.balanceOf(address(vault), uint256(h));
            uint256 claimable;
            for (uint256 j; j < actors.length; ++j) {
                sum += vault.balanceOf(actors[j], uint256(h));
                (,,, uint256 c) = vault.positionOf(h, actors[j]);
                claimable += c;
            }
            PitVault.House memory s = vault.getHouse(h);
            assertEq(sum, s.totalShares, "balances != supply");
            assertLe(claimable, s.claimableTotal, "claimable exceeds what is set aside");
        }
    }

    /// @dev Coverage of the run that just ended (shown with -vv).
    function afterInvariant() public view {
        console.log("rounds", handler.rounds());
        console.log("rounds that returned 0", handler.zeroReturns());
        console.log("wipeouts", handler.wipeouts());
        console.log("queued deposits", handler.queuedDeposits());
        console.log("queued withdrawals", handler.queuedWithdrawals());
        console.log("claims", handler.claims());
        console.log("taxed inflows refused", handler.refusedInflows());
        console.log("round returns that were taxed", handler.taxedReturns());
    }

    /// @dev While a round runs, the house's capital and shares are exactly what they were at lock time.
    /// forge-config: default.invariant.fail-on-revert = true
    /// forge-config: default.invariant.depth = 250
    function invariant_lockedHouseIsFrozen() public view {
        for (uint256 i; i < houses.length; ++i) {
            PitVault.House memory s = vault.getHouse(houses[i]);
            if (!s.locked) continue;
            (uint256 lp, uint256 endowment, uint256 shares) = handler.snaps(houses[i]);
            assertEq(s.lpAssets, lp);
            assertEq(s.endowment, endowment);
            assertEq(s.totalShares, shares);
            assertEq(s.sent, lp + endowment);
        }
    }
}
