// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {PoolModifyLiquidityTest} from "v4-core/test/PoolModifyLiquidityTest.sol";

import {IntegrationFixture} from "./IntegrationFixture.sol";
import {IFallpitRouter} from "../../src/interfaces/IFallpitRouter.sol";
import {FallpitRouter} from "../../src/FallpitRouter.sol";
import {MockChip} from "../hook/mocks/MockChips.sol";

/// @notice `commitWithEth`: native coin swapped for the round's chip on its ETH pool and committed as a buy,
///         in one call. The chip/ETH pool is a plain v4 pool on the fixture's local PoolManager (ETH as
///         currency0, fee 10000, tick spacing 200, no hooks), seeded with full-range liquidity at about
///         1,000 chips per ETH.
contract CommitWithEthTest is IntegrationFixture {
    /// @dev 1.0001^69000: about 992 chips per ETH.
    int24 internal constant START_TICK = 69_000;
    int24 internal constant FULL_RANGE = 887_200;

    PoolModifyLiquidityTest internal lpRouter;
    PoolKey internal ethKey;
    address internal dan = makeAddr("dan");

    function setUp() public override {
        super.setUp();
        lpRouter = new PoolModifyLiquidityTest(IPoolManager(address(pm)));
        MockChip(address(chip)).mint(address(this), 10_000_000e18);
        chip.approve(address(lpRouter), type(uint256).max);
        vm.deal(address(this), 10_000 ether);

        ethKey = _key(10_000, 200);
        pm.initialize(ethKey, TickMath.getSqrtPriceAtTick(START_TICK));
        _addLiquidity(ethKey, -FULL_RANGE, FULL_RANGE, 1e22);

        vm.deal(dan, 100 ether);
        _open();
    }

    /// @dev The liquidity helper sends back the ETH it did not use.
    receive() external payable {}

    function _key(uint24 fee, int24 spacing) internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(chip)),
            fee: fee,
            tickSpacing: spacing,
            hooks: IHooks(address(0))
        });
    }

    function _addLiquidity(PoolKey memory key, int24 lower, int24 upper, int256 liquidity) internal {
        lpRouter.modifyLiquidity{value: 1_000 ether}(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: lower, tickUpper: upper, liquidityDelta: liquidity, salt: bytes32(0)
            }),
            ""
        );
    }

    function _buyWithEth(address user, uint256 eth, uint256 shares, uint256 minChips)
        internal
        returns (uint256 id)
    {
        vm.prank(user);
        id = router.commitWithEth{value: FILL_FEE + eth}(
            roundId, HIGHER, shares, minChips, type(uint256).max, uint64(block.timestamp)
        );
    }

    // ------------------------------------------------------------------------------------- happy path

    function test_commitWithEth_swapsCommitsAndFills() public {
        assertEq(chip.balanceOf(dan), 0, "dan starts with ETH only");
        uint256 ethBefore = dan.balance;
        uint256 id = _buyWithEth(dan, 2 ether, 1_000e18, 1_500e18);

        IFallpitRouter.Commit memory c = router.getCommit(id);
        assertEq(c.user, dan, "the commit is the caller's");
        assertTrue(c.isBuy);
        assertEq(c.shares, 1_000e18);
        assertEq(c.limit, c.escrow, "every chip received is the limit");
        assertGe(c.escrow, 1_500e18, "at least minChips");
        assertLt(c.escrow, 2_000e18, "about 992 chips per ETH less the pool fee");
        assertEq(uint64(c.fillFee), FILL_FEE);
        assertEq(dan.balance, ethBefore - FILL_FEE - 2 ether, "all ETH used: the fill fee and the swap");
        assertEq(chip.balanceOf(address(router)), c.escrow, "the router holds the escrow");
        assertEq(router.escrowed(address(chip)), c.escrow);
        assertEq(address(router).balance, FILL_FEE, "the router holds the fill fee only");

        assertTrue(_fill(id, S0));
        assertEq(_token(HIGHER).balanceOf(dan), 1_000e18, "the tokens go to the caller");
        uint256 left = chip.balanceOf(dan);
        assertGt(left, 0, "unspent chips go back to the caller");
        assertLt(left, c.escrow);
        assertEq(chip.balanceOf(address(router)), 0, "the router keeps nothing");
        assertEq(router.escrowed(address(chip)), 0);
        assertEq(address(router).balance, 0);
    }

    function test_commitWithEth_slippage_minChips() public {
        uint256 ethBefore = dan.balance;
        vm.prank(dan);
        vm.expectRevert(); // TooFewChips(chips, minChips)
        router.commitWithEth{value: FILL_FEE + 1 ether}(
            roundId, HIGHER, 100e18, 1_000e18, type(uint256).max, uint64(block.timestamp)
        );
        assertEq(dan.balance, ethBefore, "nothing spent");

        // the exact error with its numbers
        vm.prank(dan);
        try router.commitWithEth{value: FILL_FEE + 1 ether}(
            roundId, HIGHER, 100e18, 1_000e18, type(uint256).max, uint64(block.timestamp)
        ) {
            revert("no revert");
        } catch (bytes memory err) {
            assertEq(bytes4(err), IFallpitRouter.TooFewChips.selector);
            (uint256 got, uint256 wanted) = abi.decode(_args(err), (uint256, uint256));
            assertGt(got, 900e18);
            assertLt(got, 1_000e18);
            assertEq(wanted, 1_000e18);
        }
    }

    function test_commitWithEth_needsMoreThanTheFillFee() public {
        vm.prank(dan);
        vm.expectRevert(IFallpitRouter.WrongFillFee.selector);
        router.commitWithEth{value: FILL_FEE}(
            roundId, HIGHER, 100e18, 0, type(uint256).max, uint64(block.timestamp)
        );
        vm.prank(dan);
        vm.expectRevert(IFallpitRouter.UnknownProduct.selector);
        router.commitWithEth{value: FILL_FEE + 1 ether}(
            roundId, 200, 100e18, 0, type(uint256).max, uint64(block.timestamp)
        );
    }

    function test_commitWithEth_belowMinimumTrade_revertsWholly() public {
        uint256 ethBefore = dan.balance;
        vm.prank(dan);
        vm.expectRevert(IFallpitRouter.ZeroAmount.selector);
        router.commitWithEth{value: FILL_FEE + 1 ether}(
            roundId, HIGHER, 0, 0, type(uint256).max, uint64(block.timestamp)
        );
        assertEq(dan.balance, ethBefore);
    }

    // ------------------------------------------------------------------------------------- refunds

    function test_commitWithEth_timeoutRefund_returnsChipsAndFeeToTheCaller() public {
        uint256 id = _buyWithEth(dan, 1 ether, 1_000e18, 0);
        IFallpitRouter.Commit memory c = router.getCommit(id);
        uint256 ethAfterCommit = dan.balance;
        _warp(c.fillTs + c.refundDelay + 1);
        vm.prank(makeAddr("anyone"));
        router.refund(id);
        assertEq(chip.balanceOf(dan), c.escrow, "the whole escrow comes back as chips");
        assertEq(dan.balance, ethAfterCommit + FILL_FEE, "the fill fee comes back to the caller");
        assertEq(router.feePayerOf(id), address(0), "the caller paid the fee");
        assertEq(chip.balanceOf(address(router)), 0);
        assertEq(address(router).balance, 0);
    }

    function test_commitWithEth_refundInsideFill_returnsChipsToTheCaller() public {
        uint256 cap = hook.getConfig(roundId).maxFill;
        uint256 id = _buyWithEth(dan, 1 ether, cap + 1, 0);
        uint256 escrow = router.getCommit(id).escrow;
        assertFalse(_fill(id, S0), "over the per-fill cap: refunded");
        assertEq(chip.balanceOf(dan), escrow, "the chips come back whole");
        assertEq(_token(HIGHER).balanceOf(dan), 0);
        assertEq(chip.balanceOf(address(router)), 0);
    }

    // ------------------------------------------------------------------------------------- pools

    function test_commitWithEth_thinPool_sendsBackTheEthItCouldNotSwap() public {
        // a second pool for the chip with liquidity only in a narrow band, set as the chip's ETH pool
        PoolKey memory thin = _key(3_000, 60);
        pm.initialize(thin, TickMath.getSqrtPriceAtTick(START_TICK));
        _addLiquidity(thin, START_TICK - 600, START_TICK + 600, 1e20);
        vm.prank(owner);
        router.setEthPool(address(chip), 3_000, 60, address(0));
        PoolKey memory k = router.ethPoolKey(address(chip));
        assertEq(k.fee, 3_000);
        assertEq(k.tickSpacing, 60);

        uint256 ethBefore = dan.balance;
        uint256 id = _buyWithEth(dan, 50 ether, 1_000e18, 0);
        IFallpitRouter.Commit memory c = router.getCommit(id);
        uint256 spent = ethBefore - dan.balance - FILL_FEE;
        assertGt(spent, 0);
        assertLt(spent, 50 ether, "the ETH the pool could not take came back");
        assertGt(c.escrow, 0);
        assertEq(address(router).balance, FILL_FEE, "no ETH stays in the router but the fill fee");

        // back to the default pool
        vm.prank(owner);
        router.setEthPool(address(chip), 0, 0, address(0));
        k = router.ethPoolKey(address(chip));
        assertEq(k.fee, 10_000);
        assertEq(k.tickSpacing, 200);
        assertEq(address(k.hooks), address(0));
        assertEq(Currency.unwrap(k.currency0), address(0));
        assertEq(Currency.unwrap(k.currency1), address(chip));
    }

    /// @notice The deploy renounced the router's deployer: only the book's owner sets ETH pools, and the
    ///         right follows the book's ownership.
    function test_setEthPool_onlyTheBooksOwner() public {
        assertEq(router.deployer(), address(0), "renounced in the deploy");
        vm.prank(dan);
        vm.expectRevert(IFallpitRouter.OnlyDeployerOrOwner.selector);
        router.setEthPool(address(chip), 3_000, 60, address(0));
        // the deploy's creator (this test) keeps nothing
        vm.expectRevert(IFallpitRouter.OnlyDeployerOrOwner.selector);
        router.setEthPool(address(chip), 3_000, 60, address(0));

        vm.prank(owner);
        router.setEthPool(address(chip), 3_000, 60, address(0));
        assertEq(router.ethPoolKey(address(chip)).fee, 3_000);

        // a new owner of the book takes the right over
        address multisig = makeAddr("multisig");
        vm.prank(owner);
        book.transferOwnership(multisig);
        vm.prank(multisig);
        book.acceptOwnership();
        vm.prank(owner);
        vm.expectRevert(IFallpitRouter.OnlyDeployerOrOwner.selector);
        router.setEthPool(address(chip), 0, 0, address(0));
        vm.prank(multisig);
        router.setEthPool(address(chip), 0, 0, address(0));
        assertEq(router.ethPoolKey(address(chip)).fee, 10_000);
    }

    function test_commitWithEth_noPool_reverts() public {
        vm.prank(owner);
        router.setEthPool(address(chip), 500, 10, address(0)); // a pool that was never initialized
        vm.prank(dan);
        vm.expectRevert();
        router.commitWithEth{value: FILL_FEE + 1 ether}(
            roundId, HIGHER, 100e18, 0, type(uint256).max, uint64(block.timestamp)
        );
    }

    // ------------------------------------------------------------------------------------- limits and rights

    /// @notice The buy's limit is `min(limit, chips received)`; the chips above it go back at once.
    function test_commitWithEth_limit_capsTheEscrow_restBackAtOnce() public {
        vm.prank(dan);
        uint256 id = router.commitWithEth{value: FILL_FEE + 2 ether}(
            roundId, HIGHER, 1_000e18, 1_500e18, 1_200e18, uint64(block.timestamp)
        );
        IFallpitRouter.Commit memory c = router.getCommit(id);
        assertEq(c.limit, 1_200e18, "the limit asked for");
        assertEq(c.escrow, 1_200e18, "only the limit is escrowed");
        uint256 back = chip.balanceOf(dan);
        assertGt(back, 300e18, "the chips above the limit went back to the caller");
        assertEq(chip.balanceOf(address(router)), 1_200e18);
        assertEq(router.escrowed(address(chip)), 1_200e18);

        assertTrue(_fill(id, S0));
        assertEq(_token(HIGHER).balanceOf(dan), 1_000e18);
        assertEq(chip.balanceOf(address(router)), 0, "the router keeps nothing");
    }

    /// @notice A limit above what the swap gives escrows every chip received.
    function test_commitWithEth_limitAboveChips_escrowsAll() public {
        vm.prank(dan);
        uint256 id = router.commitWithEth{value: FILL_FEE + 1 ether}(
            roundId, HIGHER, 100e18, 0, 5_000e18, uint64(block.timestamp)
        );
        IFallpitRouter.Commit memory c = router.getCommit(id);
        assertEq(c.limit, c.escrow);
        assertLt(c.escrow, 5_000e18);
        assertEq(chip.balanceOf(dan), 0);
    }

    /// @notice A buy whose limit cannot pay for the shares is refunded by the fill, chips back whole.
    function test_commitWithEth_tightLimit_refundedWithLimit() public {
        vm.prank(dan);
        uint256 id = router.commitWithEth{value: FILL_FEE + 1 ether}(
            roundId, HIGHER, 1_000e18, 0, 1e18, uint64(block.timestamp)
        );
        uint256 before = chip.balanceOf(dan);
        assertFalse(_fill(id, S0), "limit too low");
        assertEq(chip.balanceOf(dan), before + 1e18);
    }

    /// @notice A deadline.
    function test_commitWithEth_deadline() public {
        uint64 deadline = uint64(block.timestamp) - 1;
        vm.prank(dan);
        vm.expectRevert(IFallpitRouter.OrderExpired.selector);
        router.commitWithEth{value: FILL_FEE + 1 ether}(
            roundId, HIGHER, 100e18, 0, type(uint256).max, deadline
        );
        vm.prank(dan);
        vm.expectRevert(IFallpitRouter.ZeroAmount.selector);
        router.commitWithEth{value: FILL_FEE + 1 ether}(
            roundId, HIGHER, 100e18, 0, 0, uint64(block.timestamp)
        );
    }

    /// @notice Only pools with no hooks.
    function test_setEthPool_refusesHookedPools() public {
        vm.prank(owner);
        vm.expectRevert(IFallpitRouter.PoolHasHooks.selector);
        router.setEthPool(address(chip), 3_000, 60, address(0xbeef));
    }

    /// @notice `renounceDeployer` ends the deployer's `setEthPool` and `setHook` for ever.
    function test_renounceDeployer_endsTheDeployersRights() public {
        FallpitRouter fresh = new FallpitRouter(IPoolManager(address(pm)));
        assertEq(fresh.deployer(), address(this));
        fresh.setEthPool(address(chip), 3_000, 60, address(0)); // the deployer may, before it renounces
        vm.prank(dan);
        vm.expectRevert(IFallpitRouter.OnlyDeployer.selector);
        fresh.renounceDeployer();

        vm.expectEmit(true, false, false, false, address(fresh));
        emit IFallpitRouter.DeployerRenounced(address(this));
        fresh.renounceDeployer();
        assertEq(fresh.deployer(), address(0));
        vm.expectRevert(IFallpitRouter.OnlyDeployerOrOwner.selector);
        fresh.setEthPool(address(chip), 3_000, 60, address(0));
        vm.expectRevert(IFallpitRouter.OnlyDeployer.selector);
        fresh.setHook(address(hook));
        vm.expectRevert(IFallpitRouter.OnlyDeployer.selector);
        fresh.renounceDeployer();

        // the deployed router: renounced by the deploy, and the default pool works
        assertEq(router.deployer(), address(0));
        vm.expectRevert(IFallpitRouter.OnlyDeployer.selector);
        router.setHook(address(hook));
        _buyWithEth(dan, 1 ether, 100e18, 0);
    }

    /// @dev The ABI arguments of revert data (after the selector).
    function _args(bytes memory err) internal pure returns (bytes memory a) {
        a = new bytes(err.length - 4);
        for (uint256 i; i < a.length; ++i) {
            a[i] = err[i + 4];
        }
    }
}
