// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {PitOracle} from "../src/PitOracle.sol";
import {PitVault} from "../src/PitVault.sol";
import {FallpitHook} from "../src/FallpitHook.sol";
import {FallpitRouter} from "../src/FallpitRouter.sol";
import {IPitBook} from "../src/hook/IPitBook.sol";
import {PitBook} from "../src/hook/PitBook.sol";
import {PitLister} from "../src/listing/PitLister.sol";

/// @notice Read-only check of a broadcast deployment, to run before anyone funds a house. The deploy's own
///         checks (`VaultAddressMismatch`, `HookNotWired`) run in its simulation; this reads the chain after
///         the broadcast: every contract has code, the hook, vault, router and book point at each other, the
///         router's deployer renounced, the linked libraries hold the recorded code, the oracle's signers and
///         threshold and the book's guardian and fee recipient are the recorded roles, and the book's fill
///         fee is the expected one. Sends nothing.
///
///         forge script script/CheckDeployment.s.sol --rpc-url <rpc>
///
///         Reads DEPLOYMENTS_FILE (default `deployments/<chain id>.json`); FILL_FEE (wei, default 25e12) is
///         the fill fee to expect.
contract CheckDeployment is Script {
    string internal json;
    uint256 internal failures;

    function run() external {
        json = vm.readFile(
            vm.envOr("DEPLOYMENTS_FILE", string.concat("deployments/", vm.toString(block.chainid), ".json"))
        );
        PitOracle oracle = PitOracle(_addr(".contracts.PitOracle.address"));
        PitVault vault = PitVault(_addr(".contracts.PitVault.address"));
        FallpitHook hook = FallpitHook(payable(_addr(".contracts.FallpitHook.address")));
        FallpitRouter router = FallpitRouter(payable(_addr(".contracts.FallpitRouter.address")));
        PitBook book = PitBook(payable(_addr(".contracts.PitBook.address")));

        string[13] memory names = [
            "LadderMath",
            "PitOracle",
            "ChipGuard",
            "PitVault",
            "PitBook",
            "FallpitRouter",
            "FallpitHook",
            "FallpitLens",
            "FallpitDirectory",
            "CommunityTreasury",
            "AnchorRegistry",
            "PitLister",
            "VaultFeeForwarderFactory"
        ];
        for (uint256 i; i < names.length; ++i) {
            _check(_addr(string.concat(".contracts.", names[i], ".address")).code.length != 0, names[i]);
        }

        // the circular wiring
        _check(vault.hook() == address(hook), "vault.hook is the hook");
        _check(address(hook.vault()) == address(vault), "hook.vault is the vault");
        _check(hook.router() == address(router), "hook.router is the router");
        _check(address(router.hook()) == address(hook), "router.hook is the hook");
        _check(router.deployer() == address(0), "the router's deployer renounced");
        _check(book.hook() == address(hook), "book.hook is the hook");
        _check(address(hook.book()) == address(book), "hook.book is the book");
        _check(address(book.oracle()) == address(oracle), "book.oracle is the oracle");
        _check(address(hook.oracle()) == address(oracle), "hook.oracle is the oracle");

        // the linked libraries hold the recorded code
        string[4] memory libs = ["RoundLogic", "PitBookRules", "PitBookLogic", "SessionLogic"];
        for (uint256 i; i < libs.length; ++i) {
            string memory key = string.concat(".libraries.", libs[i]);
            if (!vm.keyExistsJson(json, key)) {
                _check(false, string.concat(libs[i], " recorded"));
                continue;
            }
            address lib = vm.parseJsonAddress(json, string.concat(key, ".address"));
            bytes32 hash = vm.parseJsonBytes32(json, string.concat(key, ".codeHash"));
            _check(lib.code.length != 0 && lib.codehash == hash, string.concat(libs[i], " code"));
        }

        // roles
        address[] memory signers = vm.parseJsonAddressArray(json, ".roles.keeperSigners");
        address[] memory onChain = oracle.signers();
        bool same = onChain.length == signers.length;
        for (uint256 i; same && i < signers.length; ++i) {
            same = onChain[i] == signers[i];
        }
        _check(same, "oracle signers");
        _check(oracle.threshold() == vm.parseJsonUint(json, ".roles.keeperThreshold"), "oracle threshold");
        _check(book.guardian() == vm.parseJsonAddress(json, ".roles.guardian"), "book guardian");
        _check(book.feeRecipient() == vm.parseJsonAddress(json, ".roles.feeRecipient"), "book fee recipient");
        address owner = vm.parseJsonAddress(json, ".roles.owner");
        address deployer = vm.parseJsonAddress(json, ".deployer");
        _check(book.owner() == owner || book.owner() == deployer, "book owner is OWNER or the deployer");
        _check(oracle.owner() == owner || oracle.owner() == deployer, "oracle owner is OWNER or the deployer");

        // parameters
        IPitBook.Params memory p = book.defaultParams();
        _check(p.fillFee == vm.envOr("FILL_FEE", uint256(25e12)), "fill fee");
        if (block.chainid == 4663) {
            PitLister lister = PitLister(vm.parseJsonAddress(json, ".contracts.PitLister.address"));
            _check(lister.minSeedUsd() == vm.envOr("MIN_SEED_USD", uint256(50)), "listing min seed (USD)");
        }

        if (failures != 0) revert(string.concat(vm.toString(failures), " check(s) failed"));
        console.log("deployment checks passed");
    }

    function _addr(string memory key) internal view returns (address) {
        return vm.parseJsonAddress(json, key);
    }

    function _check(bool ok, string memory what) internal {
        if (ok) {
            console.log("ok  ", what);
        } else {
            console.log("FAIL", what);
            ++failures;
        }
    }
}
