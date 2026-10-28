// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Ownable} from "solady/auth/Ownable.sol";

import {IAnchorSource} from "../interfaces/IAnchorSource.sol";

/// @title AnchorRegistry
/// @notice Finds the ticker a coin plays: the asset the coin was launched against (its anchor), read from the
///         launchpad by a trusted source, and the ticker named for that anchor.
/// @dev The registry names tickers only. Whether a ticker can host markets (a registration in `PitBook` and a
///      feed in `PitOracle`) is the vault's gate, checked when a house is created. The owner can only change
///      the lists below; the registry holds no funds.
///      Order of the lookup: the owner's manual entry for the coin first, then each source in order; the
///      first source that knows the coin decides, even when its anchor has no ticker.
contract AnchorRegistry is Ownable {
    /// @notice The result of `inspect`.
    enum Status {
        /// @dev the coin's anchor has a ticker
        Named,
        /// @dev no manual entry and no source knows the coin
        UnknownLaunch,
        /// @dev the coin's anchor has no ticker
        AnchorNotListed
    }

    struct Manual {
        bool set;
        address anchor;
    }

    /// @notice Most sources `inspect` will ask.
    uint256 public constant MAX_SOURCES = 8;

    /// @notice The ticker named for an anchor; zero when none. address(0) is native ETH.
    mapping(address anchor => bytes32) public tickerOf;

    /// @notice The owner's anchor for a coin no source knows, or for a coin that hosts another anchor than
    ///         its launch pair.
    mapping(address coin => Manual) public manualOf;

    IAnchorSource[] internal _sources;

    event TickerNamed(address indexed anchor, bytes32 ticker);
    event ManualSet(address indexed coin, bool set, address anchor);
    event SourceAdded(address indexed source);
    event SourceRemoved(address indexed source);

    error ZeroAddress();
    error TooManySources();
    error SourceExists();
    error NoSuchSource();
    error UnknownLaunch(address coin);
    error AnchorNotListed(address coin, address anchor);

    /// @param owner_ the address that manages the lists
    constructor(address owner_) {
        if (owner_ == address(0)) revert ZeroAddress();
        _initializeOwner(owner_);
    }

    // ---------------------------------------------------------------------------------------------
    // Owner
    // ---------------------------------------------------------------------------------------------

    /// @notice Names `ticker` for `anchor`; zero removes the name.
    function nameTicker(address anchor, bytes32 ticker) external onlyOwner {
        tickerOf[anchor] = ticker;
        emit TickerNamed(anchor, ticker);
    }

    /// @notice Sets (or clears) the anchor of `coin` by hand. It beats every source.
    function setManual(address coin, bool set, address anchor) external onlyOwner {
        if (coin == address(0)) revert ZeroAddress();
        manualOf[coin] = set ? Manual(true, anchor) : Manual(false, address(0));
        emit ManualSet(coin, set, set ? anchor : address(0));
    }

    /// @notice Trusts `source`, asked after the sources already trusted.
    function addSource(IAnchorSource source) external onlyOwner {
        if (address(source) == address(0)) revert ZeroAddress();
        uint256 n = _sources.length;
        if (n >= MAX_SOURCES) revert TooManySources();
        for (uint256 i; i < n; ++i) {
            if (_sources[i] == source) revert SourceExists();
        }
        _sources.push(source);
        emit SourceAdded(address(source));
    }

    /// @notice Stops trusting `source`. The order of the others is kept.
    function removeSource(IAnchorSource source) external onlyOwner {
        uint256 n = _sources.length;
        for (uint256 i; i < n; ++i) {
            if (_sources[i] == source) {
                for (uint256 j = i; j + 1 < n; ++j) {
                    _sources[j] = _sources[j + 1];
                }
                _sources.pop();
                emit SourceRemoved(address(source));
                return;
            }
        }
        revert NoSuchSource();
    }

    // ---------------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------------

    /// @notice The trusted sources, in the order they are asked.
    function sources() external view returns (IAnchorSource[] memory) {
        return _sources;
    }

    /// @notice What the registry knows about `coin`. Never reverts on a coin; for the app's checks.
    /// @return status whether the coin's anchor has a ticker, or why not
    /// @return ticker the ticker (zero unless `Named`)
    /// @return anchor the coin's anchor (zero for `UnknownLaunch`; address(0) is also native ETH)
    /// @return source the source that knew the coin, or this registry for a manual entry (zero for
    ///         `UnknownLaunch`)
    function inspect(address coin)
        public
        view
        returns (Status status, bytes32 ticker, address anchor, address source)
    {
        Manual memory m = manualOf[coin];
        if (m.set) {
            (anchor, source) = (m.anchor, address(this));
        } else {
            uint256 n = _sources.length;
            bool known;
            for (uint256 i; i < n && !known; ++i) {
                (known, anchor) = _sources[i].anchorOf(coin);
                if (known) source = address(_sources[i]);
            }
            if (!known) return (Status.UnknownLaunch, bytes32(0), address(0), address(0));
        }
        ticker = tickerOf[anchor];
        status = ticker == bytes32(0) ? Status.AnchorNotListed : Status.Named;
    }

    /// @notice The ticker `coin` plays; reverts when there is none.
    function resolve(address coin) external view returns (bytes32 ticker, address anchor, address source) {
        Status status;
        (status, ticker, anchor, source) = inspect(coin);
        if (status == Status.UnknownLaunch) revert UnknownLaunch(coin);
        if (status == Status.AnchorNotListed) revert AnchorNotListed(coin, anchor);
    }
}
