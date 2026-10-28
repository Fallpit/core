// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IERC20Min {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @notice Faithful mock of Doppler's `FeesManager` (whetstoneresearch/doppler, src/base/FeesManager.sol):
///         the same storage, the same `collectFees`, `updateBeneficiary` and `_releaseFees` logic, the same
///         errors. Only `_collectFees` differs: instead of collecting from Uniswap v4 positions it hands out
///         fees a test queued with `accrue`.
/// @dev Two versions exist. The one deployed on Robinhood Chain (commit bda077cf) lets anyone call
///      `updateBeneficiary` (a caller without shares moves nothing). Repo HEAD (5754c7e) adds
///      `CallerNotBeneficiary`. `strict` selects the HEAD behaviour.
contract MockFeesManager {
    uint256 internal constant WAD = 1e18;

    struct PoolKey {
        address currency0;
        address currency1;
        uint24 fee;
        int24 tickSpacing;
        address hooks;
    }

    error InvalidNewBeneficiary();
    error CallerNotBeneficiary();
    error Reentrancy();

    event Release(bytes32 indexed poolId, address indexed beneficiary, uint256 fees0, uint256 fees1);
    event Collect(bytes32 indexed poolId, uint256 fees0, uint256 fees1);
    event UpdateBeneficiary(bytes32 poolId, address oldBeneficiary, address newBeneficiary);

    mapping(bytes32 => uint256) public getCumulatedFees0;
    mapping(bytes32 => uint256) public getCumulatedFees1;
    mapping(bytes32 => mapping(address => uint256)) public getLastCumulatedFees0;
    mapping(bytes32 => mapping(address => uint256)) public getLastCumulatedFees1;
    mapping(bytes32 => mapping(address => uint256)) public getShares;
    mapping(bytes32 => PoolKey) public getPoolKey;

    mapping(bytes32 => uint128) internal _uncollected0;
    mapping(bytes32 => uint128) internal _uncollected1;
    bool internal _entered;
    bool public immutable strict;

    constructor(bool strict_) {
        strict = strict_;
    }

    modifier nonReentrant() {
        if (_entered) revert Reentrancy();
        _entered = true;
        _;
        _entered = false;
    }

    /// @notice Test setup: registers a pool and its beneficiaries (shares in WAD, summing to 1e18).
    function initPool(
        bytes32 poolId,
        address currency0,
        address currency1,
        address[] calldata beneficiaries,
        uint96[] calldata shares
    ) external {
        getPoolKey[poolId] = PoolKey(currency0, currency1, 0x800000, 8, address(this));
        uint256 total;
        for (uint256 i; i < beneficiaries.length; ++i) {
            getShares[poolId][beneficiaries[i]] = shares[i];
            total += shares[i];
        }
        require(total == WAD, "shares");
    }

    /// @notice Test setup: fees the pool's positions earned and that the next `collectFees` will collect.
    ///         Pulls the tokens from the caller.
    function accrue(bytes32 poolId, uint128 fees0, uint128 fees1) external {
        PoolKey memory key = getPoolKey[poolId];
        if (fees0 != 0) IERC20Min(key.currency0).transferFrom(msg.sender, address(this), fees0);
        if (fees1 != 0) IERC20Min(key.currency1).transferFrom(msg.sender, address(this), fees1);
        _uncollected0[poolId] += fees0;
        _uncollected1[poolId] += fees1;
    }

    function collectFees(bytes32 poolId) external nonReentrant returns (uint128 fees0, uint128 fees1) {
        fees0 = _uncollected0[poolId];
        fees1 = _uncollected1[poolId];
        _uncollected0[poolId] = 0;
        _uncollected1[poolId] = 0;

        getCumulatedFees0[poolId] += fees0;
        getCumulatedFees1[poolId] += fees1;

        _releaseFees(poolId, msg.sender);

        emit Collect(poolId, fees0, fees1);
    }

    function updateBeneficiary(bytes32 poolId, address newBeneficiary) external nonReentrant {
        require(newBeneficiary != msg.sender, InvalidNewBeneficiary());
        if (strict) require(getShares[poolId][msg.sender] > 0, CallerNotBeneficiary());

        _releaseFees(poolId, msg.sender);
        _releaseFees(poolId, newBeneficiary);

        if (getShares[poolId][newBeneficiary] == 0) {
            getLastCumulatedFees0[poolId][newBeneficiary] = getCumulatedFees0[poolId];
            getLastCumulatedFees1[poolId][newBeneficiary] = getCumulatedFees1[poolId];
        }

        getShares[poolId][newBeneficiary] += getShares[poolId][msg.sender];
        getShares[poolId][msg.sender] = 0;

        emit UpdateBeneficiary(poolId, msg.sender, newBeneficiary);
    }

    function _releaseFees(bytes32 poolId, address beneficiary) internal {
        uint256 shares = getShares[poolId][beneficiary];

        if (shares > 0) {
            PoolKey memory poolKey = getPoolKey[poolId];
            uint256 delta0 = getCumulatedFees0[poolId] - getLastCumulatedFees0[poolId][beneficiary];
            uint256 amount0 = delta0 * shares / WAD;
            getLastCumulatedFees0[poolId][beneficiary] = getCumulatedFees0[poolId];
            if (amount0 > 0) IERC20Min(poolKey.currency0).transfer(beneficiary, amount0);

            uint256 delta1 = getCumulatedFees1[poolId] - getLastCumulatedFees1[poolId][beneficiary];
            uint256 amount1 = delta1 * shares / WAD;
            getLastCumulatedFees1[poolId][beneficiary] = getCumulatedFees1[poolId];
            if (amount1 > 0) IERC20Min(poolKey.currency1).transfer(beneficiary, amount1);

            emit Release(poolId, beneficiary, amount0, amount1);
        }
    }
}

/// @notice A hostile fees manager: claims any pool key and calls back into a target during `collectFees`.
contract HostileFeesManager {
    address public currency0;
    address public currency1;
    address public target;
    bytes public payload;

    function setKey(address currency0_, address currency1_) external {
        currency0 = currency0_;
        currency1 = currency1_;
    }

    function arm(address target_, bytes calldata payload_) external {
        target = target_;
        payload = payload_;
    }

    function getPoolKey(bytes32) external view returns (address, address, uint24, int24, address) {
        return (currency0, currency1, 0, 0, address(0));
    }

    function collectFees(bytes32) external returns (uint128, uint128) {
        if (target != address(0)) {
            (bool ok, bytes memory ret) = target.call(payload);
            if (!ok) {
                assembly {
                    revert(add(ret, 0x20), mload(ret))
                }
            }
        }
        return (0, 0);
    }
}

/// @notice Stand-in for the Pons v2 factory: `getLaunchedToken(coin)` returns a record whose first word is
///         the coin itself for coins it launched, zero otherwise. `isLaunched` is the boolean flavour.
contract MockLaunchRegistry {
    mapping(address => bool) public isLaunched;

    function setLaunched(address coin, bool launched) external {
        isLaunched[coin] = launched;
    }

    function getLaunchedToken(address coin)
        external
        view
        returns (address token, address curve, address deployer, uint256 extra)
    {
        if (isLaunched[coin]) return (coin, address(0xC0), address(0xD0), 42);
    }
}
