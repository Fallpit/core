// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {LibString} from "solady/utils/LibString.sol";

import {FallpitDeployer} from "./FallpitDeployer.sol";
import {PitOracle} from "../src/PitOracle.sol";
import {PitVault} from "../src/PitVault.sol";
import {PitLister} from "../src/listing/PitLister.sol";
import {IPitBook} from "../src/hook/IPitBook.sol";
import {FaucetCoin} from "../src/testnet/FaucetCoin.sol";
import {MirrorFeed, MirrorStockToken} from "../src/testnet/MirrorFeed.sol";
import {TestLaunchpad} from "../src/testnet/TestLaunchpad.sol";
import {AnchorRegistry} from "../src/listing/AnchorRegistry.sol";
import {LaunchRecordSource} from "../src/listing/LaunchRecordSource.sol";
import {ChipGuard} from "../src/ChipGuard.sol";

/// @title DeployTestnet
/// @notice Deploys and wires all of Fallpit on Robinhood Chain testnet (46630), typically in two runs.
///         `run()`: the pricing engine, the oracle, the chip guard, the vault, the book, the router, the
///         hook at its CREATE2 address, the lens and the community treasury; then the testnet pieces:
///         FaucetCoin chips, one MirrorFeed and stock token stub per ticker, the tickers set in the oracle
///         and registered in the book, the guardian and the fee recipient. A ticker's registration and
///         the guardian take effect `OWNER_DELAY` later (24 hours on mainnet, zero on a testnet), and a
///         house can be created only for a ticker in force, so the houses come in the second run:
///         `createHouses()` makes one house per pair it is given, optionally seeded with the deployer's own
///         coins. With `OWNER_DELAY` zero the second run follows at once.
/// @dev Everything comes from environment variables (names in `contracts/.env.example`); nothing secret is
///      read from a file in the repository, printed or logged.
///
///      DEPLOYER_PRIVATE_KEY  required. Pays for the deployment and runs the setup.
///      OWNER                 owner of the oracle, chip guard, book and treasury (default: the deployer).
///                            When it is another address the book's ownership is only offered: that
///                            address must call `acceptOwnership()` on the book.
///      GUARDIAN              may dispute a keeper close in its challenge window (default: OWNER); in
///                            force 24 hours after the deployment
///      FEE_RECIPIENT         receives the protocol's fee share (default: OWNER)
///      VOL_KEEPER            may set the learned sigma of open rounds (`FallpitHook.setSigmaEff`, house vol
///                            learning; default: none, which keeps every round on its opening sigma); in
///                            force OWNER_DELAY after the deployment. Set it to the keeper's sender address.
///      KEEPER_SIGNERS        comma-separated keeper signer addresses (default: none; adding them later
///                            takes 24 hours to come into force)
///      KEEPER_THRESHOLD      signatures a keeper print needs (default: a strict majority)
///      OWNER_DELAY           seconds before a ticker registration, a reseed, a guardian or new defaults
///                            take effect (default 86400; the testnet run sets 0)
///      SIGNER_DELAY          seconds before a signer set or threshold change takes effect (default 86400;
///                            the testnet run sets 0)
///      MIRROR_PUSHER         address that copies mainnet Chainlink rounds into the MirrorFeeds (default:
///                            the deployer). It must not be a keeper signer: the script refuses
///      TICKERS               comma-separated tickers out of the built-in table (default: the six stocks
///                            and ETH; BTC is in the table too)
///      CHIP_NAMES, CHIP_SYMBOLS  comma-separated FaucetCoin names and symbols
///      CHIP_SUPPLY           whole coins minted once to the deployer per chip (default 10,000,000)
///      CHIP_ADDRESSES        comma-separated chips that exist already: approved and recorded, not deployed
///                            (CHIP_NAMES, CHIP_SYMBOLS and CHIP_SUPPLY are then unused)
///      POOL_MANAGER, PYTH    override the Robinhood Chain addresses
///
///      `createHouses()` reads VAULT (the PitVault of the first run), CHIPS (comma-separated chip
///      addresses), HOUSES (the pairs to create, `TICKER:CHIPSYMBOL` comma-separated, for example
///      `GME:RAT,GME:SIREN,ETH:PIT`; unset, every TICKERS ticker in every CHIPS chip), TICKERS (only for
///      that fallback) and SEED_PER_HOUSE (whole coins the deployer deposits into each house as an LP,
///      default 100,000; 0 for none).
///
///      The deployment record. `run()` writes `deployments/<chain id>.json` (`46630.json` on testnet) with
///      every address, a deploy block per contract, the chips and the tickers; `createHouses()` fills in
///      its `houses`. A run without `--broadcast` writes `<chain id>.dry-run.json` instead, so a dry run
///      never leaves a record of contracts that do not exist. DEPLOYMENTS_FILE overrides the path (it
///      must stay under `deployments/`, the scripts' only writable directory).
///      A deploy block is the chain's head when the script ran (by its
///      RPC: on Robinhood Chain `block.number` is the parent chain's): every contract of the run was
///      created in that block or a later one, so it is a safe `fromBlock`.
///
///      Testnet trust. On testnet a keeper print is bounded by a MirrorFeed whose rounds the mirror
///      pusher writes: the bound is only as good as the pusher. Keep the pusher's key apart from every
///      signer's (the script enforces distinct addresses) and tell users that testnet prices are signed
///      by the operator.
///
///      Not configured here: the round parameters (fill fee 0.0001 ETH, loss limit 30%, fees, no product
///      cap) and the menu of products every round opens with (eight floors of the close and the HIGHER /
///      LOWER pair, a minimum price of 0.02 chips a ticket) are the PitBook's built-in defaults, and the
///      keeper band (60 bps) and the close lag (300 s) are the PitOracle's. The owner can change them
///      afterwards inside the contracts' bounds (`PitBook.setDefaultParams`, 24 hours ahead;
///      `PitOracle.setTicker`).
///
///      Fill source policy: the tickers the operator's Pyth key can read (TSLA, QQQ) are `TrustlessOnly`,
///      as is BTC; every other ticker is `KeeperOnly` and is priced by keeper prints bounded by its
///      MirrorFeed. ETH is among them: the key cannot read the crypto feeds either (Hermes answers 403).
///      Every ticker also gets its Pyth feed id, so anyone holding an entitled Pyth key can replace a
///      keeper-recorded close with a trustless one.
///
///      Clocks: every stock runs on `NYWeekdays` (a round per trading day, traded in the after-hours of
///      the day before, the pre-market and the regular session) with the book's default variance weights
///      (6% after-hours, 14% overnight gap, 10% pre-market, 70% regular session) and the default windows
///      (no trading from 20:00 to 04:00; the owner can switch the nights on per ticker later, with a
///      day's notice, by registering the ticker again with `windows = 15`). ETH and BTC run on
///      `EveryDay` (a round every calendar day, traded around the clock, weekends included).
contract DeployTestnet is Script, FallpitDeployer {
    /// @param seedVar starting daily variance of close-to-close log returns, WAD
    /// @param clock the clock of the ticker's rounds
    /// @param weights variance weights of the clock's segments (all zero: the book's defaults)
    /// @param windows which windows of a stock round trade (zero: the book's default, everything but the
    ///        nights)
    struct TickerSetup {
        bytes32 ticker;
        bytes32 pythFeedId;
        uint256 seedVar;
        IPitBook.Clock clock;
        IPitBook.Weights weights;
        uint8 windows;
        IPitBook.FillSource fillSource;
    }

    struct Config {
        address poolManager;
        address pyth;
        address owner;
        address guardian;
        address volKeeper;
        address feeRecipient;
        address[] signers;
        uint256 threshold;
        uint64 ownerDelay;
        uint64 signerDelay;
        address mirrorPusher;
        TickerSetup[] tickers;
        string[] chipNames;
        string[] chipSymbols;
        uint256 chipSupply;
        /// @dev CHIP_ADDRESSES: chips that exist already (approved, not deployed); names and symbols come from them
        address[] chipAddresses;
        uint256 seedPerHouse;
    }

    /// @param houses row-major: `houses[t * chips.length + c]` is the house of ticker t in chip c
    struct System {
        Core core;
        FaucetCoin[] chips;
        MirrorFeed[] feeds;
        MirrorStockToken[] stockTokens;
        bytes32[] houses;
    }

    /// @dev Decimals of the Chainlink stock feeds on Robinhood Chain mainnet.
    uint8 internal constant FEED_DECIMALS = 8;

    error UnknownTicker(string ticker);
    error UnknownChip(string symbol);
    error BadChipConfig();
    /// @dev The mirror pusher writes the references that bound the keeper's prints: it must not sign them.
    error MirrorPusherIsSigner(address account);

    /// @notice First run: everything but the houses.
    function run() external returns (System memory s) {
        uint256 key = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(key);
        Config memory cfg = configFromEnv(deployer);
        uint256 head = chainHead();

        vm.startBroadcast(key);
        s = _deployAll(cfg, deployer);
        vm.stopBroadcast();
        string memory file = deploymentsFile();
        vm.writeFile(file, deploymentJson(cfg, s, deployer, head, block.timestamp));
        console.log("deployment record written to", file);
        _log(cfg, s, deployer);
        _logParams(s);
        _logTrust(cfg);
        console.log(
            "houses: run createHouses() from this unix time on", block.timestamp + s.core.book.OWNER_DELAY()
        );
    }

    /// @notice Second run: one house per pair in `HOUSES`, a comma-separated list of `TICKER:CHIP`, for
    ///         example `GME:RAT,GME:SIREN,ETH:PIT`; each seeded by the deployer when SEED_PER_HOUSE is not
    ///         zero. A house exists only for a ticker in force, so the run is at least `OWNER_DELAY`
    ///         (24 hours on mainnet, zero on a testnet) after `run()`.
    ///
    ///         `HOUSES` unset falls back to the cross product, every ticker in `TICKERS` in every
    ///         chip in `CHIPS`. That is the matrix of all pairs: a play deployment lists its pairs instead,
    ///         because a house cannot be removed afterwards.
    function createHouses() external returns (bytes32[] memory houses) {
        uint256 key = vm.envUint("DEPLOYER_PRIVATE_KEY");
        PitVault vault = PitVault(vm.envAddress("VAULT"));
        address[] memory chips = vm.envAddress("CHIPS", ",");
        uint256 seed = vm.envOr("SEED_PER_HOUSE", uint256(100_000)) * 1e18;
        (bytes32[] memory tickers, address[] memory houseChips) = _housePairs(chips);
        uint256 head = chainHead();
        vm.startBroadcast(key);
        houses = _createHousesAt(vault, tickers, houseChips, seed);
        vm.stopBroadcast();
        string memory file = deploymentsFile();
        if (vm.exists(file)) {
            recordHouses(file, housesJson(vault, houses, head), head, block.timestamp);
            console.log("houses added to the deployment record", file);
        } else {
            console.log("no deployment record at", file, "(the houses are not recorded)");
        }
        for (uint256 i; i < houses.length; ++i) {
            console.log(
                string.concat("house ", LibString.fromSmallString(tickers[i]), " in chip "),
                FaucetCoin(houseChips[i]).symbol()
            );
            console.logBytes32(houses[i]);
        }
    }

    /// @notice Third run, testnet only: open listing. Deploys a
    ///         `TestLaunchpad`, reads it with a `LaunchRecordSource` in the Pons v2 shape, trusts it in
    ///         ChipGuard, names each ticker's anchor (`ANCHORS`, `TICKER:ADDRESS,...`; ETH is address(0), as
    ///         Pons v2 marks it) and enters every existing house's coin by hand under its ticker's anchor,
    ///         so a pasted play coin reads as listed. Run by the owner of the registry and the guard.
    function setUpListing() external returns (TestLaunchpad pad, LaunchRecordSource source) {
        uint256 key = vm.envUint("DEPLOYER_PRIVATE_KEY");
        PitVault vault = PitVault(vm.envAddress("VAULT"));
        AnchorRegistry registry = PitLister(vault.lister()).registry();
        ChipGuard guard = ChipGuard(address(vault.chipGuard()));
        string[] memory items = LibString.split(vm.envString("ANCHORS"), ",");
        bytes32[] memory tickers = new bytes32[](items.length);
        address[] memory anchors = new address[](items.length);
        for (uint256 i; i < items.length; ++i) {
            string[] memory kv = LibString.split(items[i], ":");
            tickers[i] = LibString.toSmallString(kv[0]);
            anchors[i] = vm.parseAddress(kv[1]);
        }
        bytes32[] memory houses = vault.houseIds(0, vault.houseCount());

        vm.startBroadcast(key);
        pad = new TestLaunchpad();
        source = new LaunchRecordSource(
            address(pad), TestLaunchpad.getLaunchedToken.selector, 0, LaunchRecordSource.KnownBy.Self, 4
        );
        registry.addSource(source);
        guard.setTrustedRegistry(
            address(pad), TestLaunchpad.getLaunchedToken.selector, ChipGuard.RegistryMatch.ReturnsChip
        );
        for (uint256 i; i < tickers.length; ++i) {
            registry.nameTicker(anchors[i], tickers[i]);
        }
        for (uint256 h; h < houses.length; ++h) {
            PitVault.House memory house = vault.getHouse(houses[h]);
            for (uint256 i; i < tickers.length; ++i) {
                if (tickers[i] == house.ticker) registry.setManual(house.chip, true, anchors[i]);
            }
        }
        vm.stopBroadcast();
        console.log("TestLaunchpad", address(pad));
        console.log("LaunchRecordSource", address(source));
    }

    /// @dev The (ticker, chip) pairs `createHouses` creates: `HOUSES` (`TICKER:CHIPSYMBOL,...`) when it is
    ///      set, every `TICKERS` ticker in every `CHIPS` chip otherwise. The chip is named by its symbol
    ///      and resolved against the `CHIPS` addresses by asking each coin its `symbol()`.
    function _housePairs(address[] memory chips)
        internal
        view
        returns (bytes32[] memory tickers, address[] memory houseChips)
    {
        string memory pairs = vm.envOr("HOUSES", string(""));
        if (bytes(pairs).length != 0) {
            string[] memory items = LibString.split(pairs, ",");
            tickers = new bytes32[](items.length);
            houseChips = new address[](items.length);
            for (uint256 i; i < items.length; ++i) {
                string[] memory parts = LibString.split(items[i], ":");
                require(parts.length == 2, "HOUSES entry is not TICKER:CHIP");
                tickers[i] = LibString.toSmallString(parts[0]);
                houseChips[i] = _chipBySymbol(chips, parts[1]);
            }
            return (tickers, houseChips);
        }
        string[] memory names = vm.envOr("TICKERS", ",", _defaultTickers());
        tickers = new bytes32[](names.length * chips.length);
        houseChips = new address[](names.length * chips.length);
        for (uint256 i; i < names.length; ++i) {
            for (uint256 k; k < chips.length; ++k) {
                tickers[i * chips.length + k] = LibString.toSmallString(names[i]);
                houseChips[i * chips.length + k] = chips[k];
            }
        }
    }

    /// @dev The address in `chips` whose `symbol()` is `symbol`; reverts when there is none.
    function _chipBySymbol(address[] memory chips, string memory symbol)
        internal
        view
        returns (address found)
    {
        for (uint256 i; i < chips.length; ++i) {
            if (keccak256(bytes(FaucetCoin(chips[i]).symbol())) == keccak256(bytes(symbol))) {
                return chips[i];
            }
        }
        revert UnknownChip(symbol);
    }

    /// @notice Both runs with this contract as the creator, for tests and fork tests: deploys, waits the
    ///         book's 24 hours (`vm.warp`) and creates the houses. `run` and `createHouses` do the same
    ///         from the broadcasting account.
    function deployAll(Config memory cfg) external returns (System memory s) {
        s = _deployAll(cfg, address(this));
        vm.warp(block.timestamp + s.core.book.OWNER_DELAY());
        bytes32[] memory tickers = new bytes32[](cfg.tickers.length);
        for (uint256 i; i < tickers.length; ++i) {
            tickers[i] = cfg.tickers[i].ticker;
        }
        address[] memory chips = new address[](s.chips.length);
        for (uint256 k; k < chips.length; ++k) {
            chips[k] = address(s.chips[k]);
        }
        s.houses = _createHouses(s.core.vault, tickers, chips, cfg.seedPerHouse);
    }

    /// @notice Deploys only the hook side against contracts that exist already. Whoever runs this is the
    ///         router's deployer and makes the one `setHook` call. `ownerDelay` is the book's
    ///         `OWNER_DELAY` (24 hours on mainnet, zero on a testnet).
    function deploy(
        address poolManager,
        address math,
        address oracle,
        address vault,
        address guard,
        address owner,
        uint64 ownerDelay
    ) public returns (Deployment memory d) {
        return _deployHookSide(poolManager, math, oracle, vault, guard, owner, ownerDelay);
    }

    /// @notice The configuration `run` uses: defaults, overridden by environment variables.
    function configFromEnv(address deployer) public view returns (Config memory cfg) {
        cfg.poolManager = vm.envOr("POOL_MANAGER", POOL_MANAGER);
        cfg.pyth = vm.envOr("PYTH", PYTH);
        cfg.owner = vm.envOr("OWNER", deployer);
        cfg.guardian = vm.envOr("GUARDIAN", cfg.owner);
        cfg.volKeeper = vm.envOr("VOL_KEEPER", address(0));
        cfg.feeRecipient = vm.envOr("FEE_RECIPIENT", cfg.owner);
        cfg.mirrorPusher = vm.envOr("MIRROR_PUSHER", deployer);

        cfg.signers = _sorted(vm.envOr("KEEPER_SIGNERS", ",", new address[](0)));
        // default: a strict majority of the set (2 of 3), zero for no set
        cfg.threshold = vm.envOr("KEEPER_THRESHOLD", cfg.signers.length == 0 ? 0 : cfg.signers.length / 2 + 1);

        string[] memory names = vm.envOr("TICKERS", ",", _defaultTickers());
        cfg.tickers = new TickerSetup[](names.length);
        // TRUSTLESS_TICKERS (optional) prices the named tickers by Pyth only, whatever the policy below says:
        // the local e2e uses it for ETH, whose fake Hermes answers for every feed.
        string[] memory trustless = vm.envOr("TRUSTLESS_TICKERS", ",", new string[](0));
        for (uint256 i; i < names.length; ++i) {
            cfg.tickers[i] = tickerSetup(names[i]);
            for (uint256 j; j < trustless.length; ++j) {
                if (keccak256(bytes(trustless[j])) == keccak256(bytes(names[i]))) {
                    cfg.tickers[i].fillSource = IPitBook.FillSource.TrustlessOnly;
                }
            }
        }

        // The owner and signer delays. 24 hours is the mainnet value; a testnet runs with zero so a fresh
        // deployment has its tickers in force immediately and the houses come in the same run.
        cfg.ownerDelay = uint64(vm.envOr("OWNER_DELAY", uint256(24 hours)));
        cfg.signerDelay = uint64(vm.envOr("SIGNER_DELAY", uint256(24 hours)));

        string[] memory chipNames = new string[](2);
        chipNames[0] = "Pit Rat";
        chipNames[1] = "Siren";
        string[] memory chipSymbols = new string[](2);
        chipSymbols[0] = "RAT";
        chipSymbols[1] = "SIREN";
        cfg.chipAddresses = vm.envOr("CHIP_ADDRESSES", ",", new address[](0));
        if (cfg.chipAddresses.length != 0) {
            chipNames = new string[](cfg.chipAddresses.length);
            chipSymbols = new string[](cfg.chipAddresses.length);
            for (uint256 i; i < cfg.chipAddresses.length; ++i) {
                chipNames[i] = FaucetCoin(cfg.chipAddresses[i]).name();
                chipSymbols[i] = FaucetCoin(cfg.chipAddresses[i]).symbol();
            }
        }
        cfg.chipNames = cfg.chipAddresses.length != 0 ? chipNames : vm.envOr("CHIP_NAMES", ",", chipNames);
        cfg.chipSymbols =
            cfg.chipAddresses.length != 0 ? chipSymbols : vm.envOr("CHIP_SYMBOLS", ",", chipSymbols);
        cfg.chipSupply = vm.envOr("CHIP_SUPPLY", uint256(10_000_000)) * 1e18;
        cfg.seedPerHouse = vm.envOr("SEED_PER_HOUSE", uint256(100_000)) * 1e18;
    }

    // ------------------------------------------------------------------------------ deployment record

    /// @notice Where `run` and `createHouses` keep the deployment record: DEPLOYMENTS_FILE, else
    ///         `deployments/<chain id>.json` when broadcasting and `deployments/<chain id>.dry-run.json`
    ///         when not.
    function deploymentsFile() public view returns (string memory) {
        bool live = vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)
            || vm.isContext(VmSafe.ForgeContext.ScriptResume);
        string memory byChain =
            string.concat("deployments/", vm.toString(block.chainid), live ? ".json" : ".dry-run.json");
        return vm.envOr("DEPLOYMENTS_FILE", byChain);
    }

    /// @notice The chain's newest block number as its RPC tells it (`eth_blockNumber`). Not
    ///         `block.number`: on an Arbitrum chain such as Robinhood Chain that is a number of the parent
    ///         chain, which a log query on the chain itself cannot use. Falls back to `block.number` when
    ///         there is no RPC (a test).
    function chainHead() public returns (uint256 head) {
        head = vm.getBlockNumber();
        try vm.rpc("eth_blockNumber", "[]") returns (bytes memory r) {
            if (r.length != 0 && r.length <= 32) head = uint256(bytes32(r)) >> (8 * (32 - r.length));
        } catch {}
    }

    /// @notice The record of the first run (schema 1), with an empty
    ///         `houses` list for `createHouses` to fill.
    /// @param head the chain's block when the script ran: the deploy block of every contract of the run
    /// @param at the unix time of the run
    function deploymentJson(Config memory cfg, System memory s, address deployer, uint256 head, uint256 at)
        public
        view
        returns (string memory)
    {
        Core memory c = s.core;
        string memory contracts = string.concat(
            _entry("LadderMath", address(c.math), head, false),
            _entry("PitOracle", address(c.oracle), head, false),
            _entry("ChipGuard", address(c.guard), head, false),
            _entry("PitVault", address(c.vault), head, false),
            _entry("PitBook", address(c.book), head, false),
            _entry("FallpitRouter", address(c.router), head, false),
            _entry("FallpitHook", address(c.hook), head, false),
            _entry("FallpitLens", address(c.lens), head, false),
            _entry("FallpitDirectory", address(c.directory), head, false),
            _entry("CommunityTreasury", address(c.treasury), head, false),
            _entry("AnchorRegistry", address(c.registry), head, false),
            _entry("PitLister", address(c.lister), head, false),
            _entry("VaultFeeForwarderFactory", address(c.forwarders), head, true)
        );
        string memory signers;
        for (uint256 i; i < cfg.signers.length; ++i) {
            signers = string.concat(signers, i == 0 ? "" : ",", _q(vm.toString(cfg.signers[i])));
        }
        string memory roles = string.concat(
            '{"owner":',
            _q(vm.toString(cfg.owner)),
            ',"guardian":',
            _q(vm.toString(cfg.guardian)),
            ',"volKeeper":',
            _q(vm.toString(cfg.volKeeper)),
            ',"feeRecipient":',
            _q(vm.toString(cfg.feeRecipient)),
            ',"mirrorPusher":',
            _q(vm.toString(cfg.mirrorPusher)),
            ',"keeperSigners":[',
            signers,
            '],"keeperThreshold":',
            vm.toString(cfg.threshold),
            "}"
        );
        return string.concat(
            '{"schema":1,"chainId":',
            vm.toString(block.chainid),
            ',"deployedAt":',
            vm.toString(at),
            ',"deployer":',
            _q(vm.toString(deployer)),
            ',"roles":',
            roles,
            ',"external":{"poolManager":',
            _q(vm.toString(cfg.poolManager)),
            ',"pyth":',
            _q(vm.toString(cfg.pyth)),
            '},"contracts":{',
            contracts,
            '},"chips":[',
            _chipsJson(cfg, s, head),
            '],"tickers":[',
            _tickersJson(cfg, s, head, at + s.core.book.OWNER_DELAY()),
            '],"housesFrom":',
            vm.toString(at + s.core.book.OWNER_DELAY()),
            ',"housesBlock":0,"houses":[]}'
        );
    }

    /// @notice The `houses` list of the record: one entry per house, in the order of `houses`.
    function housesJson(PitVault vault, bytes32[] memory houses, uint256 head)
        public
        view
        returns (string memory json)
    {
        json = "[";
        for (uint256 i; i < houses.length; ++i) {
            PitVault.House memory h = vault.getHouse(houses[i]);
            json = string.concat(
                json,
                i == 0 ? "{" : ",{",
                '"id":',
                _q(vm.toString(houses[i])),
                ',"ticker":',
                _q(LibString.fromSmallString(h.ticker)),
                ',"tickerId":',
                _q(vm.toString(h.ticker)),
                ',"chip":',
                _q(vm.toString(h.chip)),
                ',"chipSymbol":',
                LibString.escapeJSON(FaucetCoin(h.chip).symbol(), true),
                ',"createdBlock":',
                vm.toString(head),
                "}"
            );
        }
        json = string.concat(json, "]");
    }

    /// @notice Puts the houses into an existing record (the second run), with the chain's block and the
    ///         time of that run.
    function recordHouses(string memory file, string memory houses, uint256 head, uint256 at) public {
        vm.writeJson(houses, file, ".houses");
        vm.writeJson(vm.toString(head), file, ".housesBlock");
        vm.writeJson(vm.toString(at), file, ".housesAt");
    }

    function _chipsJson(Config memory cfg, System memory s, uint256 head)
        internal
        view
        returns (string memory json)
    {
        for (uint256 i; i < s.chips.length; ++i) {
            json = string.concat(
                json,
                i == 0 ? "{" : ",{",
                '"address":',
                _q(vm.toString(address(s.chips[i]))),
                ',"symbol":',
                LibString.escapeJSON(cfg.chipSymbols[i], true),
                ',"name":',
                LibString.escapeJSON(cfg.chipNames[i], true),
                ',"decimals":',
                vm.toString(uint256(s.chips[i].decimals())),
                ',"deployBlock":',
                vm.toString(head),
                "}"
            );
        }
    }

    function _tickersJson(Config memory cfg, System memory s, uint256 head, uint256 inForceAt)
        internal
        view
        returns (string memory json)
    {
        for (uint256 i; i < cfg.tickers.length; ++i) {
            TickerSetup memory t = cfg.tickers[i];
            // the windows waiting to come into force, or in force already (a record written after the wait)
            IPitBook.Reseed memory r = s.core.book.pendingReseed(t.ticker);
            if (r.eta == 0) r.windows = s.core.book.getTicker(t.ticker).windows;
            json = string.concat(
                json,
                i == 0 ? "{" : ",{",
                '"symbol":',
                _q(LibString.fromSmallString(t.ticker)),
                ',"id":',
                _q(vm.toString(t.ticker)),
                ',"clock":',
                _q(t.clock == IPitBook.Clock.EveryDay ? "EveryDay" : "NYWeekdays"),
                ',"fillSource":',
                _q(t.fillSource == IPitBook.FillSource.TrustlessOnly ? "TrustlessOnly" : "KeeperOnly"),
                string.concat(
                    ',"windows":',
                    vm.toString(uint256(r.windows)),
                    ',"pythFeedId":',
                    _q(vm.toString(t.pythFeedId)),
                    ',"mirrorFeed":',
                    _q(vm.toString(address(s.feeds[i]))),
                    ',"stockToken":',
                    _q(vm.toString(address(s.stockTokens[i]))),
                    ',"registeredBlock":',
                    vm.toString(head),
                    ',"inForceAt":',
                    vm.toString(inForceAt),
                    "}"
                )
            );
        }
    }

    function _entry(string memory name, address at, uint256 head, bool last)
        internal
        pure
        returns (string memory)
    {
        return string.concat(
            _q(name),
            ':{"address":',
            _q(vm.toString(at)),
            ',"deployBlock":',
            vm.toString(head),
            last ? "}" : "},"
        );
    }

    function _q(string memory s) internal pure returns (string memory) {
        return string.concat('"', s, '"');
    }

    /// @notice Built-in setup of a ticker: its Pyth feed id (from the keeper's ticker table;
    ///         ETH/USD and BTC/USD from Hermes' public feed list), a starting daily variance, its clock
    ///         and the fill source policy. Clock weights are left to the book's defaults.
    function tickerSetup(string memory name) public pure returns (TickerSetup memory t) {
        bytes32 h = keccak256(bytes(name));
        t.ticker = LibString.toSmallString(name);
        t.clock = IPitBook.Clock.NYWeekdays;
        t.fillSource = IPitBook.FillSource.KeeperOnly;
        if (h == keccak256("TSLA")) {
            t.pythFeedId = 0x16dad506d7db8da01c87581c87ca897a012a153557d4d578c3b9c9e1bc0632f1;
            t.seedVar = 0.001225e18; // 3.5% a day
            t.fillSource = IPitBook.FillSource.TrustlessOnly;
        } else if (h == keccak256("QQQ")) {
            t.pythFeedId = 0x9695e2b96ea7b3859da9ed25b7a46a920a776e2fdae19a7bcfdf2b219230452d;
            t.seedVar = 0.000144e18; // 1.2% a day
            t.fillSource = IPitBook.FillSource.TrustlessOnly;
        } else if (h == keccak256("NVDA")) {
            t.pythFeedId = 0xb1073854ed24cbc755dc527418f52b7d271f6cc967bbf8d8129112b18860a593;
            t.seedVar = 0.0009e18; // 3% a day
        } else if (h == keccak256("AAPL")) {
            t.pythFeedId = 0x49f6b65cb1de6b10eaf75e7c03ca029c306d0357e91b5311b175084a5ad55688;
            t.seedVar = 0.000324e18; // 1.8% a day
        } else if (h == keccak256("GME")) {
            t.pythFeedId = 0x6f9cd89ef1b7fd39f667101a91ad578b6c6ace4579d5f7f285a4b06aa4504be6;
            t.seedVar = 0.0016e18; // 4% a day
        } else if (h == keccak256("MSTR")) {
            t.pythFeedId = 0xe1e80251e5f5184f2195008382538e847fafc36f751896889dd3d1b1f6111f09;
            t.seedVar = 0.0025e18; // 5% a day
        } else if (h == keccak256("ETH")) {
            t.pythFeedId = 0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace;
            t.seedVar = 0.001225e18; // 3.5% a day
            t.clock = IPitBook.Clock.EveryDay;
            // KeeperOnly: the operator's Pyth key cannot read the crypto feeds (Hermes 403), so ETH is
            // priced by keeper prints bounded by its MirrorFeed like the stocks. The Pyth feed id stays, so
            // an entitled key can still replace a keeper close with a trustless one.
        } else if (h == keccak256("BTC")) {
            t.pythFeedId = 0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43;
            t.seedVar = 0.000625e18; // 2.5% a day
            t.clock = IPitBook.Clock.EveryDay;
            t.fillSource = IPitBook.FillSource.TrustlessOnly;
        } else {
            revert UnknownTicker(name);
        }
    }

    function _defaultTickers() internal pure returns (string[] memory names) {
        names = new string[](7);
        names[0] = "TSLA";
        names[1] = "NVDA";
        names[2] = "AAPL";
        names[3] = "GME";
        names[4] = "MSTR";
        names[5] = "QQQ";
        names[6] = "ETH";
    }

    /// @dev `creator` owns everything during the setup and hands over to `cfg.owner` at the end. No houses:
    ///      the tickers are in force only 24 hours later (`_createHouses`).
    function _deployAll(Config memory cfg, address creator) internal returns (System memory s) {
        if (cfg.chipNames.length != cfg.chipSymbols.length) revert BadChipConfig();
        for (uint256 i; i < cfg.signers.length; ++i) {
            if (cfg.signers[i] == cfg.mirrorPusher) revert MirrorPusherIsSigner(cfg.mirrorPusher);
        }
        s.core = _deployCore(
            CoreConfig({
                poolManager: cfg.poolManager,
                pyth: cfg.pyth,
                owner: creator,
                signers: cfg.signers,
                threshold: cfg.threshold,
                ownerDelay: cfg.ownerDelay,
                signerDelay: cfg.signerDelay
            }),
            creator
        );
        Core memory c = s.core;

        // chips: FaucetCoins, each approved by address in the chip guard
        s.chips = new FaucetCoin[](cfg.chipNames.length);
        for (uint256 i; i < s.chips.length; ++i) {
            s.chips[i] = cfg.chipAddresses.length != 0
                ? FaucetCoin(cfg.chipAddresses[i])
                : new FaucetCoin(cfg.chipNames[i], cfg.chipSymbols[i], cfg.chipSupply);
            c.guard.approve(address(s.chips[i]), true);
        }

        // tickers: a mirror feed and a stock token stub each, then the oracle and the book
        uint256 n = cfg.tickers.length;
        s.feeds = new MirrorFeed[](n);
        s.stockTokens = new MirrorStockToken[](n);
        for (uint256 i; i < n; ++i) {
            TickerSetup memory t = cfg.tickers[i];
            s.feeds[i] = new MirrorFeed(
                FEED_DECIMALS,
                string.concat(LibString.fromSmallString(t.ticker), " / USD (mirror of 4663)"),
                cfg.owner,
                cfg.mirrorPusher
            );
            s.stockTokens[i] = new MirrorStockToken(s.feeds[i], 1e18);
            PitOracle.TickerConfig memory oc;
            oc.pythFeedId = t.pythFeedId;
            oc.aggregator = address(s.feeds[i]);
            oc.stockToken = address(s.stockTokens[i]);
            c.oracle.setTicker(t.ticker, oc);
            c.book.registerTicker(t.ticker, t.seedVar, t.clock, t.weights, t.windows, t.fillSource);
        }
        c.book.setGuardian(cfg.guardian);
        if (cfg.volKeeper != address(0)) c.book.setVolKeeper(cfg.volKeeper);
        c.book.setFeeRecipient(cfg.feeRecipient);

        if (cfg.owner != creator) {
            c.oracle.transferOwnership(cfg.owner);
            c.guard.transferOwnership(cfg.owner);
            c.treasury.transferOwnership(cfg.owner);
            // two-step in the book: `cfg.owner` must accept
            c.book.transferOwnership(cfg.owner);
        }
    }

    /// @dev One house per (ticker, chip), seeded by the caller as an ordinary LP. Row-major: house of ticker
    ///      i in chip k at `i * chips.length + k`.
    /// @dev The cross product: one house per (ticker, chip) of the two lists.
    function _createHouses(PitVault vault, bytes32[] memory tickers, address[] memory chips, uint256 seed)
        internal
        returns (bytes32[] memory houses)
    {
        bytes32[] memory t = new bytes32[](tickers.length * chips.length);
        address[] memory c = new address[](tickers.length * chips.length);
        for (uint256 i; i < tickers.length; ++i) {
            for (uint256 k; k < chips.length; ++k) {
                t[i * chips.length + k] = tickers[i];
                c[i * chips.length + k] = chips[k];
            }
        }
        return _createHousesAt(vault, t, c, seed);
    }

    /// @dev Creates the house of each pair (tickers[i], chips[i]) and seeds it when `seed` is not zero.
    ///      The two lists are the same length; `createHouse` reverts on a pair that already has a house.
    function _createHousesAt(PitVault vault, bytes32[] memory tickers, address[] memory chips, uint256 seed)
        internal
        returns (bytes32[] memory houses)
    {
        houses = new bytes32[](tickers.length);
        for (uint256 i; i < tickers.length; ++i) {
            // houses go through the lister's owner route: the testnet coins have no launchpad record
            bytes32 house = PitLister(vault.lister()).createHouse(tickers[i], chips[i]);
            houses[i] = house;
            if (seed != 0) {
                FaucetCoin(chips[i]).approve(address(vault), seed);
                vault.deposit(house, seed);
            }
        }
    }

    /// @dev What testnet's keeper bound rests on, said where the deployer reads it.
    function _logTrust(Config memory cfg) internal pure {
        console.log("WARNING: on testnet the keeper bound is trust-based: the MirrorFeeds that bound keeper");
        console.log("  prints are written by the mirror pusher, so the 60 bps band holds only as long as the");
        console.log("  pusher copies mainnet faithfully. Mirror pusher:", cfg.mirrorPusher);
        console.log("  Keep its key apart from the signers' and tell users testnet prices are team-signed.");
    }

    /// @dev Insertion sort, ascending, as the oracle wants its signer set.
    function _sorted(address[] memory a) internal pure returns (address[] memory) {
        for (uint256 i = 1; i < a.length; ++i) {
            for (uint256 j = i; j > 0 && a[j - 1] > a[j]; --j) {
                (a[j - 1], a[j]) = (a[j], a[j - 1]);
            }
        }
        return a;
    }

    /// @dev The parameters that are not configured here: they are the defaults built into the book and
    ///      the oracle, and what the app and the keeper must expect of a round on this deployment.
    function _logParams(System memory s) internal view {
        IPitBook.Params memory p = s.core.book.defaultParams();
        console.log("fill fee a commit carries (wei)", p.fillFee);
        console.log("challenge window of a keeper-signed close (seconds)", p.challengeWindow);
        console.log("alpha, the depth of the book (WAD)", p.alpha);
        console.log("vega fee per share (WAD)", p.vegaFee);
        console.log("base fee and close fee (WAD)", p.baseFee, p.closeFee);
        console.log("per-fill cap (bps of the round's capital)", p.maxFillBps);
        console.log("risk budget per print second (bps of capital at g = 1)", p.riskCapBps);
        console.log("loss limit of a round (bps of its capital)", p.lossLimitBps);
        console.log("product cap of a floor (bps of the round's capital; 10000 is no cap)", p.floorCapBps);
        console.log("minimum price of a buy (wei of a chip per token)", p.minPriceWad);
        console.log("smallest capital a round opens with (whole chips)", p.minCapital);
        (uint8[] memory lo, uint8[] memory hi) = s.core.book.unpackMenu(p.menu);
        console.log("products of a round (band runs, 0 to 39)", lo.length);
        for (uint256 i; i < lo.length; ++i) {
            console.log("  product, first band, last band", i, lo[i], hi[i]);
        }
        console.log("keeper band (bps around the mirror feed)", s.core.oracle.DEFAULT_BOUND_BPS());
        console.log(
            "latest a close print may be after 16:00:00 (seconds)", s.core.oracle.DEFAULT_CLOSE_MAX_LAG()
        );
    }

    function _log(Config memory cfg, System memory s, address deployer) internal pure {
        Core memory c = s.core;
        console.log("deployer", deployer);
        console.log("owner", cfg.owner);
        console.log("LadderMath", address(c.math));
        console.log("PitOracle", address(c.oracle));
        console.log("ChipGuard", address(c.guard));
        console.log("PitVault", address(c.vault));
        console.log("CommunityTreasury", address(c.treasury));
        console.log("PitBook", address(c.book));
        console.log("FallpitRouter", address(c.router));
        console.log("FallpitHook", address(c.hook));
        console.log("FallpitLens", address(c.lens));
        console.log("FallpitDirectory", address(c.directory));
        console.log("AnchorRegistry", address(c.registry));
        console.log("PitLister", address(c.lister));
        console.log("VaultFeeForwarderFactory", address(c.forwarders));
        console.log("keeper signers", cfg.signers.length, "threshold", cfg.threshold);
        for (uint256 i; i < s.chips.length; ++i) {
            console.log(string.concat("chip ", cfg.chipSymbols[i]), address(s.chips[i]));
        }
        for (uint256 i; i < cfg.tickers.length; ++i) {
            string memory name = LibString.fromSmallString(cfg.tickers[i].ticker);
            console.log(
                string.concat("clock ", name),
                cfg.tickers[i].clock == IPitBook.Clock.EveryDay ? "EveryDay" : "NYWeekdays"
            );
            console.log(string.concat("MirrorFeed ", name), address(s.feeds[i]));
            console.log(string.concat("MirrorStockToken ", name), address(s.stockTokens[i]));
            for (uint256 k; k < s.chips.length && s.houses.length != 0; ++k) {
                console.log(string.concat("house ", name, " in ", cfg.chipSymbols[k]));
                console.logBytes32(s.houses[i * s.chips.length + k]);
            }
        }
    }
}
