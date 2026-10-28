// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {CommonBase} from "forge-std/Base.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

import {LadderMath} from "../src/LadderMath.sol";
import {PitOracle} from "../src/PitOracle.sol";
import {ChipGuard} from "../src/ChipGuard.sol";
import {PitVault} from "../src/PitVault.sol";
import {CommunityTreasury} from "../src/CommunityTreasury.sol";
import {FallpitHook} from "../src/FallpitHook.sol";
import {FallpitRouter} from "../src/FallpitRouter.sol";
import {PitBook} from "../src/hook/PitBook.sol";
import {FallpitLens} from "../src/hook/FallpitLens.sol";
import {FallpitDirectory, IFallpitHookDirectory} from "../src/hook/FallpitDirectory.sol";
import {IPyth} from "../src/oracle/IPyth.sol";
import {ILadderMath} from "../src/interfaces/ILadderMath.sol";
import {IPitOracle} from "../src/interfaces/IPitOracle.sol";
import {IPitVault, ITickerGate} from "../src/interfaces/IPitVault.sol";
import {IChipGuard} from "../src/interfaces/IChipGuard.sol";
import {IPitBook} from "../src/hook/IPitBook.sol";
import {AnchorRegistry} from "../src/listing/AnchorRegistry.sol";
import {PitLister, ISignerSet, IBookParams} from "../src/listing/PitLister.sol";
import {VaultFeeForwarderFactory} from "../src/listing/VaultFeeForwarder.sol";

/// @title FallpitDeployer
/// @notice The one deployment path of the Fallpit contracts, shared by the testnet deploy script, the
///         integration tests and the fork tests, so what the tests exercise is what gets deployed.
/// @dev Two circular dependencies are resolved here:
///      - router and hook, book and hook: the router and the book are deployed first, the hook pins their
///        addresses as immutables, then `router.setHook` and `book.setHook` are called once by their
///        deployer and are frozen. The router's deployer then renounces (`renounceDeployer`): the creator
///        keeps no right on the router, and the book's owner sets the ETH pools of chips that need one;
///      - vault and hook: each pins the other as an immutable. The vault is the creator's next CREATE, so
///        its address follows from the creator's nonce. The hook is created through the deterministic
///        deployment proxy (0x4e59...956C, on Robinhood Chain 46630 and 4663) with the fixed salt
///        `HOOK_SALT`, so its address follows from its init code alone: should its creation fail on chain
///        after the vault landed, sending it again gives the same address.
///
///      `creator` is the account that executes the CREATEs of this contract's code: the broadcaster in a
///      forge script, the calling contract itself in a test.
abstract contract FallpitDeployer is CommonBase {
    /// @dev v4 PoolManager on Robinhood Chain testnet 46630 and mainnet 4663 (the router's ETH swaps).
    address internal constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    /// @dev Pyth core contract on both chains.
    address internal constant PYTH = 0x8250f4aF4B972684F7b336503E2D6dFeDeB1487a;

    /// @notice The hook side of a deployment.
    struct Deployment {
        PitBook book;
        FallpitRouter router;
        FallpitHook hook;
        FallpitLens lens;
        FallpitDirectory directory;
    }

    /// @notice Every contract of a full deployment.
    struct Core {
        LadderMath math;
        PitOracle oracle;
        ChipGuard guard;
        PitVault vault;
        AnchorRegistry registry;
        PitLister lister;
        VaultFeeForwarderFactory forwarders;
        CommunityTreasury treasury;
        PitBook book;
        FallpitRouter router;
        FallpitHook hook;
        FallpitLens lens;
        FallpitDirectory directory;
    }

    /// @param poolManager the v4 PoolManager (the router swaps ETH for chips on it in `commitWithEth`)
    /// @param pyth the Pyth core contract
    /// @param owner owner of the oracle, the chip guard, the book and the treasury
    /// @param signers the first keeper signer set, ascending by address (may be empty)
    /// @param threshold signatures a keeper print needs (zero for an empty set)
    /// @param ownerDelay `PitBook.OWNER_DELAY`: 24 hours on mainnet, zero on a testnet
    /// @param signerDelay `PitOracle.SIGNER_DELAY`: 24 hours on mainnet, zero on a testnet
    struct CoreConfig {
        address poolManager;
        address pyth;
        address owner;
        address[] signers;
        uint256 threshold;
        uint64 ownerDelay;
        uint64 signerDelay;
    }

    /// @dev The hook's CREATE2 salt: any fixed value, so the hook's address follows from its init code.
    bytes32 internal constant HOOK_SALT = bytes32(0);

    error VaultAddressMismatch(address predicted, address actual);
    error Create2Failed();
    error NoCreate2Factory();
    error HookNotWired(address vaultHook, address hook);
    error RouterDeployerKept(address deployer);

    /// @notice Deploys and wires every contract. `creator` must be the account whose CREATEs these are.
    function _deployCore(CoreConfig memory cfg, address creator) internal returns (Core memory d) {
        if (CREATE2_FACTORY.code.length == 0) revert NoCreate2Factory();
        d.math = new LadderMath();
        d.oracle = new PitOracle(IPyth(cfg.pyth), cfg.owner, cfg.signers, cfg.threshold, cfg.signerDelay);
        d.guard = new ChipGuard(cfg.owner);
        d.book = new PitBook(d.oracle, cfg.owner, cfg.ownerDelay);
        d.router = new FallpitRouter(IPoolManager(cfg.poolManager));

        // The vault is the creator's next CREATE; the hook's CREATE2 address follows from its init code.
        address vaultAt = vm.computeCreateAddress(creator, vm.getNonce(creator));
        bytes memory initCode = abi.encodePacked(
            type(FallpitHook).creationCode,
            abi.encode(address(d.router), d.math, d.oracle, IPitVault(vaultAt), d.guard, d.book)
        );
        address hookAt = vm.computeCreate2Address(HOOK_SALT, keccak256(initCode), CREATE2_FACTORY);

        // the book gates houses: a ticker gets a house once its registration is in force
        d.vault = new PitVault(hookAt, d.guard, ITickerGate(address(d.book)));
        if (address(d.vault) != vaultAt) revert VaultAddressMismatch(vaultAt, address(d.vault));
        d.hook = _create2Hook(initCode, hookAt);
        if (d.vault.hook() != address(d.hook)) revert HookNotWired(d.vault.hook(), address(d.hook));
        _wireRouter(d.router, hookAt);
        d.book.setHook(hookAt);
        d.lens = new FallpitLens(d.hook, d.math);
        d.directory = new FallpitDirectory(IFallpitHookDirectory(address(d.hook)));
        d.treasury = new CommunityTreasury(address(d.vault), cfg.owner);
        // every house is created through the lister (anchor check, locked seed) or by its owner by hand
        d.registry = new AnchorRegistry(cfg.owner);
        d.lister = new PitLister(
            IPitVault(address(d.vault)),
            d.registry,
            ISignerSet(address(d.oracle)),
            IBookParams(address(d.book)),
            cfg.owner
        );
        d.vault.setLister(address(d.lister));
        d.forwarders = new VaultFeeForwarderFactory(IPitVault(address(d.vault)));
    }

    /// @notice Deploys only the hook side against contracts that exist already (or, for the vault, will
    ///         exist at the given address).
    function _deployHookSide(
        address poolManager,
        address math,
        address oracle,
        address vault,
        address guard,
        address owner,
        uint64 ownerDelay
    ) internal returns (Deployment memory d) {
        d.book = new PitBook(IPitOracle(oracle), owner, ownerDelay);
        d.router = new FallpitRouter(IPoolManager(poolManager));
        if (CREATE2_FACTORY.code.length == 0) revert NoCreate2Factory();
        bytes memory initCode = abi.encodePacked(
            type(FallpitHook).creationCode,
            abi.encode(
                address(d.router),
                ILadderMath(math),
                IPitOracle(oracle),
                IPitVault(vault),
                IChipGuard(guard),
                d.book
            )
        );
        address hookAt = vm.computeCreate2Address(HOOK_SALT, keccak256(initCode), CREATE2_FACTORY);
        d.hook = _create2Hook(initCode, hookAt);
        _wireRouter(d.router, hookAt);
        d.book.setHook(hookAt);
        d.lens = new FallpitLens(d.hook, ILadderMath(math));
        d.directory = new FallpitDirectory(IFallpitHookDirectory(address(d.hook)));
    }

    /// @dev Sets the router's hook, then gives up the deployer's rights and checks that nothing is left.
    function _wireRouter(FallpitRouter router, address hookAt) private {
        router.setHook(hookAt);
        router.renounceDeployer();
        if (router.deployer() != address(0)) revert RouterDeployerKept(router.deployer());
    }

    function _create2Hook(bytes memory initCode, address predicted) private returns (FallpitHook) {
        if (predicted.code.length == 0) {
            (bool ok,) = CREATE2_FACTORY.call(abi.encodePacked(HOOK_SALT, initCode));
            if (!ok || predicted.code.length == 0) revert Create2Failed();
        }
        return FallpitHook(payable(predicted));
    }
}
