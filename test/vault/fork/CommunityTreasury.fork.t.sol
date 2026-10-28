// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";

import {ChipGuard} from "../../../src/ChipGuard.sol";
import {CommunityTreasury} from "../../../src/CommunityTreasury.sol";
import {PitVault} from "../../../src/PitVault.sol";
import {ITickerGate} from "../../../src/interfaces/IPitVault.sol";
import {IPitVault} from "../../../src/interfaces/IPitVault.sol";
import {MockHook, MockOracle} from "../mocks/MockHook.sol";

interface IERC20 {
    function balanceOf(address owner) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
}

/// @notice The live DopplerHookInitializer (FeesManager plus the per-asset state).
interface IDopplerHookInitializer {
    struct BeneficiaryData {
        address beneficiary;
        uint96 shares;
    }

    function getBeneficiaries(address asset) external view returns (BeneficiaryData[] memory);
    function updateBeneficiary(bytes32 poolId, address newBeneficiary) external;
    function collectFees(bytes32 poolId) external returns (uint128 fees0, uint128 fees1);
    function getShares(bytes32 poolId, address beneficiary) external view returns (uint256);
    function getCumulatedFees0(bytes32 poolId) external view returns (uint256);
    function getCumulatedFees1(bytes32 poolId) external view returns (uint256);
    function getPoolKey(bytes32 poolId)
        external
        view
        returns (address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks);
}

/// @notice Minimal v4 swapper used only inside the fork to make the pool earn fees.
contract ForkSwapper {
    IPoolManager internal immutable manager;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    /// @notice Sells `amountIn` of currency0 for currency1.
    function sell0(PoolKey memory key, uint256 amountIn) external returns (BalanceDelta delta) {
        delta = abi.decode(manager.unlock(abi.encode(key, amountIn)), (BalanceDelta));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager));
        (PoolKey memory key, uint256 amountIn) = abi.decode(data, (PoolKey, uint256));
        BalanceDelta delta = manager.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            ""
        );
        uint256 owed = uint256(uint128(-delta.amount0()));
        manager.sync(key.currency0);
        IERC20(Currency.unwrap(key.currency0)).transfer(address(manager), owed);
        manager.settle();
        manager.take(key.currency1, address(this), uint256(uint128(delta.amount1())));
        return abi.encode(delta);
    }
}

/// @notice Fork test of `CommunityTreasury.harvest` against the real Doppler contracts on Robinhood Chain
///         mainnet (4663): the AI / NVDA pool of the DopplerHookInitializer. A real beneficiary of that pool
///         is impersonated to call `updateBeneficiary(poolId, inbox)`, exactly what a community would do.
///         Nothing is sent to the live chain.
/// @dev Skipped unless FORK_RPC_4663 is set, for example
///      `FORK_RPC_4663=https://rpc.mainnet.chain.robinhood.com forge test --match-path "test/vault/fork/*"`.
contract CommunityTreasuryForkTest is Test {
    address internal constant DOPPLER_HOOK_INITIALIZER = 0x4e3468951D49f2EEa976eD0D6e75fFCb44a9a544;
    address internal constant AIRLOCK = 0xeb7C034704eF8Dcd2D32324c1545f62fB4aD0862;
    address internal constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address internal constant AI = 0x2E8c31162b855A2ffa90F6F8634643Ad6F111e18;
    address internal constant NVDA_STOCK = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;
    bytes32 internal constant AI_NVDA_POOL =
        0xcbdfea90430a30ee4469c9902e120a77e7c7e4711d5643671c1d1957f2f1ce27;
    bytes32 internal constant DOPPLER_CLONE_HASH =
        0xf10f86b05965a827a332e6c73086f18026fbe3917f4bffbec3f938b3b5397b56;
    bytes32 internal constant NVDA = bytes32("NVDA");
    /// @dev Holder of 95% of the AI pool's fees since block 21001755 (a contract).
    address internal constant AI_FEE_HOLDER = 0x4f6C50a87bF234c45191F88Ed4cBb9f021b7dc67;

    IDopplerHookInitializer internal doppler = IDopplerHookInitializer(DOPPLER_HOOK_INITIALIZER);
    address internal treasuryOwner = makeAddr("treasuryOwner");
    PitVault internal vault;
    CommunityTreasury internal treasury;
    MockHook internal hook;
    bytes32 internal house;
    address internal inbox;
    address internal beneficiary;
    uint256 internal beneficiaryShares;
    bool internal forked;

    function setUp() public {
        string memory rpc = vm.envOr("FORK_RPC_4663", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        assertEq(block.chainid, 4663);
        forked = true;

        ChipGuard guard = new ChipGuard(address(this));
        guard.setTrustedCodeHash(DOPPLER_CLONE_HASH, true);
        MockOracle oracle = new MockOracle();
        oracle.setSupported(NVDA, true);
        hook = new MockHook();
        vault = new PitVault(address(hook), guard, ITickerGate(address(oracle)));
        vault.setLister(address(this));
        hook.setVault(IPitVault(address(vault)));
        treasury = new CommunityTreasury(address(vault), treasuryOwner);

        // The real AI coin passes the real chip check and gets its NVDA house.
        house = vault.createHouse(NVDA, AI);
        inbox = treasury.inboxOf(house);

        // The live beneficiary with the largest share. `getBeneficiaries` is only the launch record: the
        // creator side of this pool moved its 95% to AI_FEE_HOLDER with `updateBeneficiary` at block
        // 21001755, so shares are read from `getShares`. The launch entries stay as candidates (the 5%
        // protocol share has never moved), so the test keeps working if the 95% moves again.
        IDopplerHookInitializer.BeneficiaryData[] memory launch = doppler.getBeneficiaries(AI);
        _consider(AI_FEE_HOLDER);
        for (uint256 i; i < launch.length; ++i) {
            _consider(launch[i].beneficiary);
        }
    }

    function _consider(address candidate) internal {
        uint256 shares = doppler.getShares(AI_NVDA_POOL, candidate);
        if (shares > beneficiaryShares) (beneficiary, beneficiaryShares) = (candidate, shares);
    }

    modifier onlyFork() {
        if (!forked) {
            vm.skip(true);
            return;
        }
        _;
    }

    /// @dev The facts the treasury relies on, read from the live contracts.
    function testFork_livePool_isWhatTheTreasuryExpects() public onlyFork {
        assertGt(DOPPLER_HOOK_INITIALIZER.code.length, 0);
        assertGt(AIRLOCK.code.length, 0);
        (address c0, address c1,,, address hooks) = doppler.getPoolKey(AI_NVDA_POOL);
        assertEq(c0, AI);
        assertEq(c1, NVDA_STOCK);
        assertEq(hooks, DOPPLER_HOOK_INITIALIZER);
        assertGt(beneficiaryShares, 0, "a live beneficiary exists");
        assertEq(doppler.getShares(AI_NVDA_POOL, beneficiary), beneficiaryShares);
        // The launch record is stale: its creator entry holds nothing any more.
        IDopplerHookInitializer.BeneficiaryData[] memory launch = doppler.getBeneficiaries(AI);
        uint256 liveSharesOfLaunchList;
        for (uint256 i; i < launch.length; ++i) {
            liveSharesOfLaunchList += doppler.getShares(AI_NVDA_POOL, launch[i].beneficiary);
        }
        assertLt(liveSharesOfLaunchList, 1e18, "shares have moved since launch");
        assertEq(doppler.getShares(AI_NVDA_POOL, inbox), 0);
        console.log("beneficiary", beneficiary, "shares (WAD)", beneficiaryShares);
    }

    /// @dev The whole path on live state: a real beneficiary redirects its share to the house's inbox,
    ///      anyone harvests, the AI leg lands in the NVDA/AI house's endowment, the NVDA stock token leg
    ///      waits in the inbox. Uses only fees the pool had already earned at the fork block.
    function testFork_harvest_realPool_afterUpdateBeneficiary() public onlyFork {
        vm.prank(beneficiary);
        doppler.updateBeneficiary(AI_NVDA_POOL, inbox);
        assertEq(doppler.getShares(AI_NVDA_POOL, inbox), beneficiaryShares);
        assertEq(doppler.getShares(AI_NVDA_POOL, beneficiary), 0);

        _harvestAndCheck();
    }

    /// @dev Same, with fees made inside the fork by a swap, so the amounts are certainly not zero.
    function testFork_harvest_realPool_afterASwap() public onlyFork {
        vm.prank(beneficiary);
        doppler.updateBeneficiary(AI_NVDA_POOL, inbox);
        // Clear what was pending so this test measures only the swap below.
        treasury.harvest(DOPPLER_HOOK_INITIALIZER, AI_NVDA_POOL, house);
        uint256 endowmentBefore = vault.getHouse(house).endowment;

        ForkSwapper swapper = new ForkSwapper(IPoolManager(POOL_MANAGER));
        uint256 amountIn = 1_000_000e18; // about 0.1% of the AI supply
        deal(AI, address(swapper), amountIn);
        (address c0, address c1, uint24 fee, int24 tickSpacing, address hooks) =
            doppler.getPoolKey(AI_NVDA_POOL);
        PoolKey memory key = PoolKey(Currency.wrap(c0), Currency.wrap(c1), fee, tickSpacing, IHooks(hooks));
        BalanceDelta delta = swapper.sell0(key, amountIn);
        assertEq(uint256(uint128(-delta.amount0())), amountIn);
        assertGt(delta.amount1(), 0);

        (uint256 donated,) = _harvestAndCheck();
        assertGt(donated, 0, "the swap's AI fees reached the house");
        assertEq(vault.getHouse(house).endowment, endowmentBefore + donated);
        console.log("AI sold", amountIn, "AI fee share donated", donated);
    }

    /// @dev Harvesting for a house whose inbox is not a beneficiary moves nothing and does not revert.
    function testFork_harvest_realPool_withoutBeingBeneficiary() public onlyFork {
        (uint256 donated, uint256 held) = treasury.harvest(DOPPLER_HOOK_INITIALIZER, AI_NVDA_POOL, house);
        assertEq(donated, 0);
        assertEq(held, 0);
        assertEq(vault.getHouse(house).endowment, 0);
        assertEq(IERC20(AI).balanceOf(inbox), 0);
    }

    /// @dev The owner can take the stock token leg and never the AI leg.
    function testFork_owner_cannotTakeTheChipLeg() public onlyFork {
        vm.prank(beneficiary);
        doppler.updateBeneficiary(AI_NVDA_POOL, inbox);
        (, uint256 held) = treasury.harvest(DOPPLER_HOOK_INITIALIZER, AI_NVDA_POOL, house);

        vm.startPrank(treasuryOwner);
        vm.expectRevert(CommunityTreasury.ChipLegLocked.selector);
        treasury.releaseOtherLeg(house, AI, treasuryOwner, 1);
        if (held != 0) {
            treasury.releaseOtherLeg(house, NVDA_STOCK, treasuryOwner, held);
            assertEq(IERC20(NVDA_STOCK).balanceOf(treasuryOwner), held);
        }
        vm.stopPrank();

        // And the house's endowment is out of everyone's reach.
        vm.prank(treasuryOwner);
        vm.expectRevert(PitVault.InsufficientShares.selector);
        vault.requestWithdraw(house, 1);
    }

    function _harvestAndCheck() internal returns (uint256 donated, uint256 held) {
        uint256 cum0 = doppler.getCumulatedFees0(AI_NVDA_POOL);
        uint256 cum1 = doppler.getCumulatedFees1(AI_NVDA_POOL);
        uint256 vaultAiBefore = IERC20(AI).balanceOf(address(vault));
        uint256 inboxNvdaBefore = IERC20(NVDA_STOCK).balanceOf(inbox);
        uint256 endowmentBefore = vault.getHouse(house).endowment;

        address anyone = makeAddr("anyone");
        vm.prank(anyone);
        (donated, held) = treasury.harvest(DOPPLER_HOOK_INITIALIZER, AI_NVDA_POOL, house);

        // Doppler's own formula: the inbox gets its share of what the pool collected since it joined.
        uint256 fees0 = doppler.getCumulatedFees0(AI_NVDA_POOL) - cum0;
        uint256 fees1 = doppler.getCumulatedFees1(AI_NVDA_POOL) - cum1;
        assertEq(donated, fees0 * beneficiaryShares / 1e18, "AI leg = the inbox's share of the AI fees");
        assertEq(held, fees1 * beneficiaryShares / 1e18, "NVDA leg = the inbox's share of the NVDA fees");

        assertEq(IERC20(AI).balanceOf(address(vault)) - vaultAiBefore, donated, "AI is in the vault");
        assertEq(vault.getHouse(house).endowment - endowmentBefore, donated, "booked as endowment");
        assertEq(vault.totalSupply(uint256(house)), 0, "no shares minted");
        assertEq(IERC20(AI).balanceOf(inbox), 0);
        assertEq(IERC20(AI).balanceOf(address(treasury)), 0);
        assertEq(IERC20(NVDA_STOCK).balanceOf(inbox) - inboxNvdaBefore, held, "NVDA waits in the inbox");
        assertEq(IERC20(AI).balanceOf(anyone), 0, "the caller gets nothing");
        assertEq(vault.accounted(AI), IERC20(AI).balanceOf(address(vault)));
        console.log("AI donated to the NVDA/AI house", donated);
        console.log("NVDA stock token held in the inbox", held);
    }
}
