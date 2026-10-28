// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/PoolManager.sol";

import {DeployTestnet} from "../../script/DeployTestnet.s.sol";
import {PitOracle} from "../../src/PitOracle.sol";
import {PitVault} from "../../src/PitVault.sol";
import {IPitBook} from "../../src/hook/IPitBook.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IFallpitRouter} from "../../src/interfaces/IFallpitRouter.sol";
import {FaucetCoin} from "../../src/testnet/FaucetCoin.sol";
import {MockPyth} from "../oracle/mocks/MockPyth.sol";

/// @notice The testnet deploy script's whole path on a local PoolManager: every contract deployed and wired,
///         chips, mirror feeds, tickers and houses set up, ownership handed over. (The fork tests in
///         SystemFork.t.sol run the same code against the live PoolManager and Pyth.)
contract DeployTestnetScriptTest is Test {
    address internal owner = makeAddr("owner");
    address internal guardian = makeAddr("guardian");
    address internal feeRecipient = makeAddr("feeRecipient");
    address internal pusher = makeAddr("pusher");

    function _config(DeployTestnet script, address pm, address pyth)
        internal
        view
        returns (DeployTestnet.Config memory cfg)
    {
        cfg.poolManager = pm;
        cfg.pyth = pyth;
        cfg.owner = owner;
        cfg.guardian = guardian;
        cfg.feeRecipient = feeRecipient;
        cfg.signers = new address[](3);
        cfg.signers[0] = address(0x1001);
        cfg.signers[1] = address(0x1002);
        cfg.signers[2] = address(0x1003);
        cfg.threshold = 2;
        cfg.ownerDelay = 24 hours;
        cfg.signerDelay = 24 hours;
        cfg.mirrorPusher = pusher;
        // the script's default set (the six stocks and ETH), and BTC from its table
        string[8] memory names = ["TSLA", "NVDA", "AAPL", "GME", "MSTR", "QQQ", "ETH", "BTC"];
        cfg.tickers = new DeployTestnet.TickerSetup[](8);
        for (uint256 i; i < 8; ++i) {
            cfg.tickers[i] = script.tickerSetup(names[i]);
        }
        cfg.chipNames = new string[](2);
        cfg.chipNames[0] = "Pit Rat";
        cfg.chipNames[1] = "Siren";
        cfg.chipSymbols = new string[](2);
        cfg.chipSymbols[0] = "RAT";
        cfg.chipSymbols[1] = "SIREN";
        cfg.chipSupply = 10_000_000e18;
        cfg.seedPerHouse = 100_000e18;
    }

    function test_deployAll_deploysWiresAndSetsUpEverything() public {
        vm.warp(1_791_000_000);
        PoolManager pm = new PoolManager(address(this));
        MockPyth pyth = new MockPyth();
        DeployTestnet script = new DeployTestnet();
        DeployTestnet.Config memory cfg = _config(script, address(pm), address(pyth));
        DeployTestnet.System memory s = script.deployAll(cfg);

        // wiring: the circular references closed
        assertEq(s.core.hook.router(), address(s.core.router));
        assertEq(address(s.core.router.hook()), address(s.core.hook));
        assertEq(address(s.core.hook.vault()), address(s.core.vault));
        assertEq(s.core.vault.hook(), address(s.core.hook));
        assertEq(s.core.vault.router(), address(s.core.router), "vault sessions: the vault trusts the router");
        // buy with ETH: every chip swaps on its default SYM/ETH pool (ETH, chip, 1%, 200, no hooks)
        PoolKey memory ek = s.core.router.ethPoolKey(address(s.chips[0]));
        assertEq(Currency.unwrap(ek.currency0), address(0));
        assertEq(Currency.unwrap(ek.currency1), address(s.chips[0]));
        assertEq(ek.fee, 10_000);
        assertEq(ek.tickSpacing, 200);
        assertEq(address(ek.hooks), address(0));
        assertEq(address(s.core.hook.book()), address(s.core.book));
        assertEq(address(s.core.hook.oracle()), address(s.core.oracle));
        assertEq(address(s.core.hook.math()), address(s.core.math));
        assertEq(address(s.core.hook.chipGuard()), address(s.core.guard));
        assertEq(address(s.core.router.poolManager()), address(pm));
        assertEq(address(s.core.vault.gate()), address(s.core.book), "the book gates houses");
        assertEq(s.core.book.hook(), address(s.core.hook));
        assertEq(address(s.core.vault.chipGuard()), address(s.core.guard));
        assertEq(address(s.core.treasury.vault()), address(s.core.vault));
        assertEq(address(s.core.lens.hook()), address(s.core.hook));
        assertEq(address(s.core.book.oracle()), address(s.core.oracle));
        // the router's deployer renounced in the deploy: nobody can wire it again
        assertEq(s.core.router.deployer(), address(0));
        vm.prank(address(script));
        vm.expectRevert(IFallpitRouter.OnlyDeployer.selector);
        s.core.router.setHook(address(s.core.hook));

        // ownership: handed to the configured owner (the book's in two steps)
        assertEq(s.core.oracle.owner(), owner);
        assertEq(s.core.guard.owner(), owner);
        assertEq(s.core.treasury.owner(), owner);
        assertEq(s.core.book.owner(), address(script));
        assertEq(s.core.book.pendingOwner(), owner);
        vm.prank(owner);
        s.core.book.acceptOwnership();
        assertEq(s.core.book.owner(), owner);
        assertEq(s.core.book.guardian(), guardian);
        assertEq(s.core.book.feeRecipient(), feeRecipient);

        // the keeper set is in force from the first block
        assertEq(s.core.oracle.threshold(), 2);
        assertEq(s.core.oracle.signers().length, 3);

        // the parameters a round opened on this deployment gets: nothing is passed to the script, they
        // are the book's own defaults
        IPitBook.Params memory params = s.core.book.defaultParams();
        assertEq(params.fillFee, 0.0001 ether, "the trader-paid fill fee");
        // the book's defaults
        assertEq(params.lossLimitBps, 3000, "the per-round loss limit: 30% of the capital");
        assertEq(params.floorCapBps, 10_000, "no product cap on a floor");
        assertEq(params.minPriceWad, 0.02e18, "the minimum price of a buy");
        assertEq(params.menu, s.core.book.DEFAULT_MENU(), "the menu: eight floors and the pair");
        (uint8[] memory lo, uint8[] memory hi) = s.core.book.unpackMenu(params.menu);
        assertEq(lo.length, 10);
        assertEq(hi[9], 39);
        assertEq(params.alpha, 0.2e18, "alpha 0.2");
        assertEq(params.maxFillBps, 2000);
        assertEq(params.challengeWindow, 900, "a keeper-signed close can be challenged for 15 minutes");

        // chips: faucet coins, approved one by one
        assertEq(s.chips.length, 2);
        for (uint256 k; k < 2; ++k) {
            (bool allowed, bool taxed) = s.core.guard.check(address(s.chips[k]));
            assertTrue(allowed);
            assertFalse(taxed);
            assertEq(s.chips[k].decimals(), 18);
            assertEq(s.chips[k].totalSupply(), 10_000_000e18);
        }
        assertEq(s.chips[0].symbol(), "RAT");
        assertEq(s.chips[1].name(), "Siren");

        // tickers: a mirror feed and a stock token stub each; fill source by what the Pyth key can read;
        // the stocks on the New York weekday clock, ETH and BTC on the every-day clock
        for (uint256 i; i < 8; ++i) {
            bytes32 ticker = cfg.tickers[i].ticker;
            PitOracle.TickerConfig memory oc = s.core.oracle.config(ticker);
            assertEq(oc.pythFeedId, cfg.tickers[i].pythFeedId);
            assertTrue(oc.pythFeedId != bytes32(0));
            assertEq(oc.aggregator, address(s.feeds[i]));
            assertEq(oc.stockToken, address(s.stockTokens[i]));
            assertEq(oc.boundBps, 60, "the keeper band: the oracle's default");
            assertEq(s.feeds[i].decimals(), 8);
            assertEq(s.feeds[i].pusher(), pusher);
            assertEq(s.feeds[i].owner(), owner);
            assertEq(s.stockTokens[i].uiMultiplier(), 1e18);
            assertTrue(s.core.oracle.supported(ticker));
            IPitBook.Ticker memory tk = s.core.book.getTicker(ticker);
            assertEq(tk.varWad, cfg.tickers[i].seedVar);
            bool crypto = ticker == bytes32("ETH") || ticker == bytes32("BTC");
            // ETH is keeper-priced: the deployer's Pyth key cannot read the crypto feeds either (Hermes 403)
            bool pythFill = ticker == bytes32("TSLA") || ticker == bytes32("QQQ") || ticker == bytes32("BTC");
            assertEq(
                uint8(tk.fillSource),
                uint8(pythFill ? IPitBook.FillSource.TrustlessOnly : IPitBook.FillSource.KeeperOnly)
            );
            assertEq(uint8(tk.clock), uint8(crypto ? IPitBook.Clock.EveryDay : IPitBook.Clock.NYWeekdays));
            assertEq(tk.windows, crypto ? 15 : 13, "stocks: no trading from 20:00 to 04:00 by default");
            if (crypto) {
                assertEq(tk.weights.regular, 10_000, "one segment from close to close");
            } else {
                assertEq(tk.weights.afterHours, 600);
                assertEq(tk.weights.gap, 1400);
                assertEq(tk.weights.preMarket, 1000);
                assertEq(tk.weights.regular, 7000);
            }
            // houses: one per (ticker, chip), seeded
            for (uint256 k; k < 2; ++k) {
                bytes32 house = s.houses[i * 2 + k];
                assertEq(house, s.core.vault.houseId(ticker, address(s.chips[k])));
                assertEq(s.core.vault.chipOf(house), address(s.chips[k]));
                assertEq(s.core.vault.roundCapital(house), 100_000e18);
            }
        }
        assertEq(s.feeds[0].description(), "TSLA / USD (mirror of 4663)");
        assertEq(s.feeds[6].description(), "ETH / USD (mirror of 4663)");
        assertEq(
            s.core.oracle.config(bytes32("ETH")).pythFeedId,
            0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace,
            "Pyth ETH/USD"
        );
        assertEq(s.chips[0].balanceOf(address(s.core.vault)), 800_000e18);
        assertEq(s.chips[0].balanceOf(address(script)), 9_200_000e18);
    }

    /// @dev The deployment record both runs write (`deployments/46630.json` on testnet): its first-run
    ///      content, then the houses put in by the second run, through a real file.
    function test_deploymentRecord_firstRunThenHouses() public {
        vm.warp(1_791_000_000);
        PoolManager pm = new PoolManager(address(this));
        DeployTestnet script = new DeployTestnet();
        DeployTestnet.Config memory cfg = _config(script, address(pm), address(new MockPyth()));
        DeployTestnet.System memory s = script.deployAll(cfg);
        string memory json = script.deploymentJson(cfg, s, address(this), 79_000_000, 1_791_000_000);

        assertEq(vm.parseJsonUint(json, ".schema"), 1);
        assertEq(vm.parseJsonUint(json, ".chainId"), block.chainid);
        assertEq(vm.parseJsonUint(json, ".deployedAt"), 1_791_000_000);
        assertEq(vm.parseJsonAddress(json, ".deployer"), address(this));
        assertEq(vm.parseJsonAddress(json, ".roles.owner"), owner);
        assertEq(vm.parseJsonAddress(json, ".roles.guardian"), guardian);
        assertEq(vm.parseJsonAddress(json, ".roles.mirrorPusher"), pusher);
        assertEq(vm.parseJsonAddressArray(json, ".roles.keeperSigners").length, 3);
        assertEq(vm.parseJsonUint(json, ".roles.keeperThreshold"), 2);
        assertEq(vm.parseJsonAddress(json, ".external.poolManager"), address(pm));
        assertEq(vm.parseJsonAddress(json, ".contracts.FallpitHook.address"), address(s.core.hook));
        assertEq(vm.parseJsonUint(json, ".contracts.FallpitHook.deployBlock"), 79_000_000);
        assertEq(vm.parseJsonAddress(json, ".contracts.FallpitRouter.address"), address(s.core.router));
        assertEq(vm.parseJsonAddress(json, ".contracts.FallpitLens.address"), address(s.core.lens));
        assertEq(vm.parseJsonAddress(json, ".contracts.FallpitDirectory.address"), address(s.core.directory));
        assertEq(vm.parseJsonAddress(json, ".contracts.PitBook.address"), address(s.core.book));
        assertEq(vm.parseJsonAddress(json, ".contracts.PitVault.address"), address(s.core.vault));
        assertEq(vm.parseJsonAddress(json, ".contracts.PitOracle.address"), address(s.core.oracle));
        assertEq(vm.parseJsonAddress(json, ".contracts.ChipGuard.address"), address(s.core.guard));
        assertEq(vm.parseJsonAddress(json, ".contracts.CommunityTreasury.address"), address(s.core.treasury));
        assertEq(vm.parseJsonAddress(json, ".contracts.LadderMath.address"), address(s.core.math));
        assertEq(vm.parseJsonAddress(json, ".contracts.AnchorRegistry.address"), address(s.core.registry));
        assertEq(vm.parseJsonAddress(json, ".contracts.PitLister.address"), address(s.core.lister));
        assertEq(
            vm.parseJsonAddress(json, ".contracts.VaultFeeForwarderFactory.address"),
            address(s.core.forwarders)
        );
        assertEq(vm.parseJsonAddress(json, ".chips[1].address"), address(s.chips[1]));
        assertEq(vm.parseJsonString(json, ".chips[0].symbol"), "RAT");
        assertEq(vm.parseJsonString(json, ".chips[1].name"), "Siren");
        assertEq(vm.parseJsonUint(json, ".chips[0].decimals"), 18);
        assertEq(vm.parseJsonString(json, ".tickers[0].symbol"), "TSLA");
        assertEq(vm.parseJsonBytes32(json, ".tickers[0].id"), bytes32("TSLA"));
        assertEq(vm.parseJsonString(json, ".tickers[0].fillSource"), "TrustlessOnly");
        assertEq(vm.parseJsonString(json, ".tickers[1].fillSource"), "KeeperOnly");
        assertEq(vm.parseJsonString(json, ".tickers[6].clock"), "EveryDay");
        assertEq(vm.parseJsonString(json, ".tickers[1].clock"), "NYWeekdays");
        assertEq(vm.parseJsonUint(json, ".tickers[1].windows"), 13);
        assertEq(vm.parseJsonUint(json, ".tickers[6].windows"), 15);
        assertEq(vm.parseJsonAddress(json, ".tickers[1].mirrorFeed"), address(s.feeds[1]));
        assertEq(vm.parseJsonBytes32(json, ".tickers[1].pythFeedId"), cfg.tickers[1].pythFeedId);
        assertEq(vm.parseJsonUint(json, ".tickers[1].inForceAt"), 1_791_000_000 + 24 hours);
        assertEq(vm.parseJsonUint(json, ".housesFrom"), 1_791_000_000 + 24 hours);
        assertEq(vm.parseJsonUint(json, ".housesBlock"), 0);
        assertEq(vm.parseJsonBytes32Array(json, ".houses").length, 0);

        // the second run puts the houses in
        string memory file = "deployments/.test-record.json";
        vm.writeFile(file, json);
        script.recordHouses(
            file, script.housesJson(s.core.vault, s.houses, 79_100_000), 79_100_000, 1_791_090_000
        );
        string memory back = vm.readFile(file);
        vm.removeFile(file);
        assertEq(vm.parseJsonAddress(back, ".contracts.FallpitHook.address"), address(s.core.hook), "kept");
        assertEq(vm.parseJsonUint(back, ".housesAt"), 1_791_090_000);
        assertEq(vm.parseJsonUint(back, ".housesBlock"), 79_100_000);
        assertEq(vm.parseJsonBytes32(back, ".houses[0].id"), s.houses[0]);
        assertEq(vm.parseJsonBytes32(back, ".houses[15].id"), s.houses[15]);
        assertEq(vm.parseJsonString(back, ".houses[0].ticker"), "TSLA");
        assertEq(vm.parseJsonBytes32(back, ".houses[0].tickerId"), bytes32("TSLA"));
        assertEq(vm.parseJsonAddress(back, ".houses[1].chip"), address(s.chips[1]));
        assertEq(vm.parseJsonString(back, ".houses[1].chipSymbol"), "SIREN");
        assertEq(vm.parseJsonUint(back, ".houses[3].createdBlock"), 79_100_000);
        assertFalse(vm.exists(file));

        // the directory sees the same deployment
        assertEq(address(s.core.directory.hook()), address(s.core.hook));
        assertEq(address(s.core.directory.vault()), address(s.core.vault));
        assertEq(s.core.directory.tickers().length, 8);
        assertEq(s.core.directory.houses().length, 16);
        assertEq(s.core.directory.houses()[15].house, s.houses[15]);
    }

    function test_tickerSetup_knownTickersOnly() public {
        DeployTestnet script = new DeployTestnet();
        DeployTestnet.TickerSetup memory t = script.tickerSetup("TSLA");
        assertEq(t.ticker, bytes32("TSLA"));
        assertEq(t.pythFeedId, 0x16dad506d7db8da01c87581c87ca897a012a153557d4d578c3b9c9e1bc0632f1);
        assertEq(uint8(t.fillSource), uint8(IPitBook.FillSource.TrustlessOnly));
        assertEq(uint8(t.clock), uint8(IPitBook.Clock.NYWeekdays));
        t = script.tickerSetup("GME");
        assertEq(uint8(t.fillSource), uint8(IPitBook.FillSource.KeeperOnly));
        assertEq(uint8(t.clock), uint8(IPitBook.Clock.NYWeekdays));
        t = script.tickerSetup("ETH");
        assertEq(t.ticker, bytes32("ETH"));
        assertEq(t.pythFeedId, 0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace);
        // KeeperOnly: the deployer's Pyth key cannot read the crypto feeds either (Hermes 403)
        assertEq(uint8(t.fillSource), uint8(IPitBook.FillSource.KeeperOnly));
        assertEq(uint8(t.clock), uint8(IPitBook.Clock.EveryDay));
        t = script.tickerSetup("BTC");
        assertEq(t.pythFeedId, 0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43);
        assertEq(uint8(t.clock), uint8(IPitBook.Clock.EveryDay));
        vm.expectRevert(abi.encodeWithSelector(DeployTestnet.UnknownTicker.selector, "HIMS"));
        script.tickerSetup("HIMS");
    }

    function test_deployAll_withoutSeedOrSigners() public {
        vm.warp(1_791_000_000);
        PoolManager pm = new PoolManager(address(this));
        DeployTestnet script = new DeployTestnet();
        DeployTestnet.Config memory cfg = _config(script, address(pm), address(new MockPyth()));
        cfg.signers = new address[](0);
        cfg.threshold = 0;
        cfg.seedPerHouse = 0;
        cfg.owner = address(script); // no handover
        DeployTestnet.System memory s = script.deployAll(cfg);
        assertEq(s.core.oracle.threshold(), 0);
        assertEq(s.core.book.owner(), address(script));
        assertEq(s.core.book.pendingOwner(), address(0));
        assertEq(s.core.vault.roundCapital(s.houses[0]), 0);
        // every ticker is still supported through its Pyth feed id
        assertTrue(s.core.oracle.supported(bytes32("NVDA")));
    }
}
