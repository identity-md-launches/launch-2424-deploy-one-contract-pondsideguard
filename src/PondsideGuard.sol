// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {SafeCast} from "v4-core/libraries/SafeCast.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {TransientStateLibrary} from "v4-core/libraries/TransientStateLibrary.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/types/BeforeSwapDelta.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/types/PoolOperation.sol";

/// @notice The slice of the pool token's interface the hook relies on.
interface IPoolToken {
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function burn(uint256 amount) external;
}

/// @title PondsideGuard
/// @notice A standalone Uniswap v4 hook for native-ETH / token pools. It owns no token and no pool: anyone may
/// initialize a new ETH / token pool with it on the configured PoolManager, and every such pool gets its own
/// buy-cap window, jar and buyback. For each pool the hook
///   1. takes 1% of the ETH side of every swap as a fee for `feeRecipient`, paid inside the swap (or minted as an
///      ERC-6909 claim the hook holds for the recipient when the PoolManager cannot pay it directly);
///   2. caps each wallet (`tx.origin`) at 1% of the token's total supply bought during the first 10 minutes of
///      trading (the window opens with the pool's first swap);
///   3. takes another 1% of the ETH side into the pool's jar and, once the jar holds at least 0.1 ETH, buys the
///      pool's token from the pool with the jar and burns it (automatically after the swap that filled the jar
///      when that succeeds, otherwise through `buyback(poolId)` which anyone may call);
///   4. lets `owner` pause and unpause swaps. Liquidity is never hooked, so it can always be removed.
/// @dev When ETH is the swap's specified currency the fee is charged through the beforeSwap delta. To charge 1% of
/// the ETH that really moves (not of the request) the hook first runs the swap itself and reverts it, reading the
/// fill the PoolManager will produce, so a swap stopped early by its price limit or by thin liquidity pays only on
/// the filled part. The hook's own swaps skip the hook callbacks, which is how the PoolManager treats a swap whose
/// caller is the pool's hook. Liquidity and donate callbacks are not enabled.
contract PondsideGuard is IHooks, IUnlockCallback {
    using Hooks for IHooks;
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using SafeCast for uint256;
    using SafeCast for int256;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    // ---------------------------------------------------------------------------------------------
    // Constants
    // ---------------------------------------------------------------------------------------------

    /// @notice Basis-point denominator.
    uint256 public constant BPS = 10_000;
    /// @notice Hook fee sent to `feeRecipient`, in basis points of the ETH side of a swap (1.0%).
    uint256 public constant FEE_BPS = 100;
    /// @notice Jar share, in basis points of the ETH side of a swap (1.0%).
    uint256 public constant JAR_BPS = 100;
    /// @notice Length of the per-wallet buy-cap window after the pool's first swap.
    uint256 public constant BUY_WINDOW = 10 minutes;
    /// @notice Per-wallet cap during the window, in basis points of the token's total supply (1.0%).
    uint256 public constant BUY_CAP_BPS = 100;
    /// @notice Jar balance at which a buyback may run.
    uint256 public constant BUYBACK_THRESHOLD = 0.1 ether;
    /// @notice How far below the block's reference sqrt price a buyback may push the pool, in basis points of the
    /// sqrt price (1% of the sqrt price is about 2% of the price). Whatever the band does not let it spend stays in
    /// the jar for a later buyback.
    uint256 public constant BUYBACK_SQRT_PRICE_BAND_BPS = 100;
    /// @notice After an automatic buyback attempt fails, swaps on that pool do not retry it for this long.
    /// `buyback(poolId)` is never delayed.
    uint256 public constant AUTO_BUYBACK_RETRY_DELAY = 5 minutes;

    uint8 private constant ACTION_CLAIM_FEES = 1;
    uint8 private constant ACTION_BUYBACK = 2;

    // ---------------------------------------------------------------------------------------------
    // Immutable configuration
    // ---------------------------------------------------------------------------------------------

    /// @notice The Uniswap v4 PoolManager this hook serves.
    IPoolManager public immutable poolManager;
    /// @notice The only privileged account. It may pause and unpause swaps and nothing else.
    address public immutable owner;
    /// @notice Receives the 1% hook fee from every pool.
    address public immutable feeRecipient;

    // ---------------------------------------------------------------------------------------------
    // State
    // ---------------------------------------------------------------------------------------------

    struct PoolState {
        /// @dev The pool's token (currency1; currency0 is always native ETH).
        Currency token;
        uint24 fee;
        int24 tickSpacing;
        bool initialized;
        /// @dev Timestamp at which the buy-cap window closes; zero until the pool's first swap.
        uint64 windowEndsAt;
        /// @dev Automatic buyback attempts are skipped before this timestamp.
        uint64 nextAutoBuybackAt;
        /// @dev Timestamp of the block whose opening price `referenceSqrtPriceX96` holds.
        uint64 referenceAt;
        /// @dev The pool's sqrt price at the hook's first interaction in the block `referenceAt`.
        uint160 referenceSqrtPriceX96;
        /// @dev ETH collected for buybacks, in wei. Held as ETH in this contract plus `jarClaims`.
        uint256 jar;
        /// @dev Part of `jar` held as ERC-6909 ETH claims on the PoolManager instead of ETH.
        uint256 jarClaims;
        /// @dev Tokens each wallet bought during the window.
        mapping(address wallet => uint256 amount) bought;
    }

    mapping(PoolId poolId => PoolState) private _pools;

    /// @notice Hook fees the PoolManager could not pay directly, held as ERC-6909 ETH claims for `feeRecipient`.
    uint256 public pendingFees;
    /// @notice Whether swaps are paused (for every pool using this hook).
    bool public paused;
    /// @notice Tokens bought back and destroyed through the token's `burn`, per token.
    mapping(address token => uint256 amount) public tokensBurned;
    /// @notice Tokens bought back that the token refused to burn, held in this contract, per token. They are
    /// offered to `burn` again at that token's next buyback.
    mapping(address token => uint256 amount) public tokensLocked;

    // ---------------------------------------------------------------------------------------------
    // Events and errors
    // ---------------------------------------------------------------------------------------------

    event PoolRegistered(PoolId indexed poolId, Currency token, uint24 fee, int24 tickSpacing);
    event WindowOpened(PoolId indexed poolId, uint256 windowEndsAt);
    event FeePaid(PoolId indexed poolId, address indexed recipient, uint256 amount);
    event FeeClaimMinted(PoolId indexed poolId, uint256 amount);
    event FeesClaimed(address indexed recipient, uint256 amount);
    event JarFunded(PoolId indexed poolId, uint256 amount, bool asClaim);
    event Buyback(PoolId indexed poolId, uint256 ethSpent, uint256 tokensBought, bool burned);
    event AutoBuybackDeferred(PoolId indexed poolId, uint256 until);
    event Paused(address indexed by);
    event Unpaused(address indexed by);

    error ZeroAddress();
    error NotPoolManager();
    error NotOwner();
    error NotSelf();
    error HookNotImplemented();
    error PairMustBeNativeEth();
    error TokenSupplyUnavailable();
    error UnknownPool();
    error SwapsPaused();
    error AlreadyPaused();
    error NotPaused();
    error BuyCapExceeded(address wallet, uint256 attemptedTotal, uint256 cap);
    error JarBelowThreshold(uint256 jar, uint256 threshold);
    error BuybackBoughtNothing();
    error BuybackPriceOutOfBand(uint160 currentSqrtPriceX96, uint160 limitSqrtPriceX96);
    error CurrencySynced();
    error NothingToClaim();
    error UnknownAction(uint8 action);
    error DirectEthNotAccepted();
    /// @dev Carries a simulated swap's delta out of the reverting simulation call.
    error SimulationResult(int256 delta);
    error SimulationDidNotRevert();

    // ---------------------------------------------------------------------------------------------
    // Construction
    // ---------------------------------------------------------------------------------------------

    /// @param poolManager_ The Uniswap v4 PoolManager on the launch chain.
    /// @param owner_ The account allowed to pause and unpause swaps.
    /// @param feeRecipient_ The wallet that receives the 1% hook fee.
    constructor(IPoolManager poolManager_, address owner_, address feeRecipient_) {
        if (address(poolManager_) == address(0) || owner_ == address(0) || feeRecipient_ == address(0)) {
            revert ZeroAddress();
        }
        poolManager = poolManager_;
        owner = owner_;
        feeRecipient = feeRecipient_;
        // Reverts unless this contract's address carries exactly the permission bits of `getHookPermissions`.
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlySelf() {
        if (msg.sender != address(this)) revert NotSelf();
        _;
    }

    /// @notice Only ETH the PoolManager pays out (fees and jar takes) is accepted.
    receive() external payable {
        if (msg.sender != address(poolManager)) revert DirectEthNotAccepted();
    }

    // ---------------------------------------------------------------------------------------------
    // Permissions
    // ---------------------------------------------------------------------------------------------

    /// @notice The callbacks this hook enables; the deployed address must carry exactly these bits.
    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /// @notice The permission bits a deployment address must carry, as a mask over the low 14 bits.
    function requiredFlags() public pure returns (uint160) {
        return Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
            | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
    }

    // ---------------------------------------------------------------------------------------------
    // Owner: pause / unpause
    // ---------------------------------------------------------------------------------------------

    /// @notice Pause swaps on every pool using this hook. Liquidity can still be added and removed.
    function pause() external onlyOwner {
        if (paused) revert AlreadyPaused();
        paused = true;
        emit Paused(msg.sender);
    }

    /// @notice Resume swaps.
    function unpause() external onlyOwner {
        if (!paused) revert NotPaused();
        paused = false;
        emit Unpaused(msg.sender);
    }

    // ---------------------------------------------------------------------------------------------
    // Public actions: claimFees / buyback
    // ---------------------------------------------------------------------------------------------

    /// @notice Redeem the hook-fee claims the PoolManager could not pay directly and send the ETH to
    /// `feeRecipient`. Anyone may call.
    function claimFees() external {
        if (pendingFees == 0) revert NothingToClaim();
        poolManager.unlock(abi.encode(ACTION_CLAIM_FEES, PoolId.wrap(0)));
    }

    /// @notice Spend the pool's jar buying its token from the pool and burn what was bought. Anyone may call
    /// once the jar holds at least `BUYBACK_THRESHOLD`. The buy stops at the block's price band (see
    /// `BUYBACK_SQRT_PRICE_BAND_BPS`); anything it could not spend stays in the jar.
    /// @param poolId The pool whose jar to spend (`PoolKey.toId()`).
    function buyback(PoolId poolId) external {
        if (paused) revert SwapsPaused();
        PoolState storage p = _pool(poolId);
        if (p.jar < BUYBACK_THRESHOLD) revert JarBelowThreshold(p.jar, BUYBACK_THRESHOLD);
        poolManager.unlock(abi.encode(ACTION_BUYBACK, poolId));
    }

    /// @notice Internal entry point for the automatic buyback attempted inside the swap that fills the jar.
    /// Only this contract may call it; it exists so that a failing buyback can be caught without reverting
    /// the swap that triggered it.
    function selfBuyback(PoolId poolId) external onlySelf {
        _executeBuyback(poolId);
    }

    /// @notice Internal entry point for the fee simulation: runs the swap the PoolManager is about to run and
    /// reverts with its delta, so the pool is left untouched. Only this contract may call it.
    function simulateSwap(PoolKey calldata key, SwapParams calldata params) external onlySelf {
        BalanceDelta delta = poolManager.swap(key, params, "");
        revert SimulationResult(BalanceDelta.unwrap(delta));
    }

    /// @inheritdoc IUnlockCallback
    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        (uint8 action, PoolId poolId) = abi.decode(data, (uint8, PoolId));
        if (action == ACTION_CLAIM_FEES) {
            uint256 amount = pendingFees;
            pendingFees = 0;
            poolManager.burn(address(this), CurrencyLibrary.ADDRESS_ZERO.toId(), amount);
            poolManager.take(CurrencyLibrary.ADDRESS_ZERO, feeRecipient, amount);
            emit FeesClaimed(feeRecipient, amount);
        } else if (action == ACTION_BUYBACK) {
            _executeBuyback(poolId);
        } else {
            revert UnknownAction(action);
        }
        return "";
    }

    // ---------------------------------------------------------------------------------------------
    // Hook callbacks
    // ---------------------------------------------------------------------------------------------

    /// @inheritdoc IHooks
    /// @dev Registers the pool. Any number of ETH / token pools may use the hook; each has its own state.
    function afterInitialize(address, PoolKey calldata key, uint160, int24) external onlyPoolManager returns (bytes4) {
        if (!key.currency0.isAddressZero()) revert PairMustBeNativeEth();
        _requireSupplyReadable(key.currency1);
        PoolId poolId = key.toId();
        PoolState storage p = _pools[poolId];
        p.token = key.currency1;
        p.fee = key.fee;
        p.tickSpacing = key.tickSpacing;
        p.initialized = true;
        emit PoolRegistered(poolId, key.currency1, key.fee, key.tickSpacing);
        return IHooks.afterInitialize.selector;
    }

    /// @inheritdoc IHooks
    /// @dev Opens the buy-cap window on the pool's first swap and records the block's reference price. When ETH
    /// is the specified currency (exact-input buy, exact-output sell) the fee is charged here as a positive
    /// specified delta computed from the ETH the pool will actually move, found by simulating the swap.
    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (paused) revert SwapsPaused();
        PoolId poolId = key.toId();
        PoolState storage p = _pool(poolId);
        _touchReference(poolId, p);
        if (p.windowEndsAt == 0) {
            p.windowEndsAt = uint64(block.timestamp + BUY_WINDOW);
            emit WindowOpened(poolId, p.windowEndsAt);
        }

        int128 specified;
        if (_ethIsSpecified(params)) {
            (uint256 fee, uint256 jarCut) = _feesForSpecifiedEth(params.amountSpecified);
            if (fee + jarCut > 0) {
                uint256 realised = _simulateEthSide(key, params, fee + jarCut);
                (fee, jarCut) = _specifiedEthFees(params.amountSpecified, realised);
                specified = (fee + jarCut).toInt128();
            }
        }
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(specified, 0), 0);
    }

    /// @inheritdoc IHooks
    /// @dev Settles both fee shares, enforces the buy cap and attempts the automatic buyback.
    function afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, int128)
    {
        PoolId poolId = key.toId();
        PoolState storage p = _pool(poolId);
        int128 eth = delta.amount0();
        uint256 ethSide = eth < 0 ? uint256(uint128(-eth)) : uint256(uint128(eth));

        uint256 fee;
        uint256 jarCut;
        int128 unspecified;
        if (_ethIsSpecified(params)) {
            // Already charged in beforeSwap on the same realised ETH side; recompute the split to settle it.
            (fee, jarCut) = _specifiedEthFees(params.amountSpecified, ethSide);
        } else if (params.amountSpecified < 0) {
            // Exact-input sell: the pool pays `ethSide` out, the trader receives it less the fees.
            (fee, jarCut) = _feesFromGross(ethSide);
            unspecified = (fee + jarCut).toInt128();
        } else {
            // Exact-output buy: the pool needs `ethSide`, the trader pays it plus the fees.
            (fee, jarCut) = _feesFromNet(ethSide);
            unspecified = (fee + jarCut).toInt128();
        }

        if (params.zeroForOne) _enforceBuyCap(poolId, p, delta.amount1());
        _collect(poolId, p, fee, jarCut);

        if (p.jar >= BUYBACK_THRESHOLD && block.timestamp >= p.nextAutoBuybackAt) {
            // The swap that fills the jar must not revert if the buyback fails.
            try this.selfBuyback(poolId) {}
            catch {
                p.nextAutoBuybackAt = uint64(block.timestamp + AUTO_BUYBACK_RETRY_DELAY);
                emit AutoBuybackDeferred(poolId, p.nextAutoBuybackAt);
            }
        }
        return (IHooks.afterSwap.selector, unspecified);
    }

    /// @inheritdoc IHooks
    function beforeInitialize(address, PoolKey calldata, uint160) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    // ---------------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------------

    /// @notice Whether `poolId` is a pool initialized with this hook.
    function isPool(PoolId poolId) public view returns (bool) {
        return _pools[poolId].initialized;
    }

    /// @notice The full key of a registered pool (currency0 is native ETH, hooks is this contract).
    function poolKey(PoolId poolId) external view returns (PoolKey memory) {
        return _key(_pool(poolId));
    }

    /// @notice The pool's token (currency1), or zero for an unknown pool.
    function poolToken(PoolId poolId) public view returns (address) {
        return Currency.unwrap(_pools[poolId].token);
    }

    /// @notice Timestamp at which the pool's per-wallet buy-cap window closes (first swap + 10 minutes), or zero
    /// while the pool has not traded yet.
    function windowEndsAt(PoolId poolId) external view returns (uint256) {
        return _pools[poolId].windowEndsAt;
    }

    /// @notice Whether the per-wallet buy cap is in force on the pool: from registration until 10 minutes after
    /// its first swap.
    function windowOpen(PoolId poolId) external view returns (bool) {
        PoolState storage p = _pools[poolId];
        return p.initialized && (p.windowEndsAt == 0 || block.timestamp < p.windowEndsAt);
    }

    /// @notice The maximum a wallet may buy during the window, in tokens, from the token's live total supply.
    function buyCap(PoolId poolId) public view returns (uint256) {
        PoolState storage p = _pools[poolId];
        if (!p.initialized) return 0;
        return IPoolToken(Currency.unwrap(p.token)).totalSupply() * BUY_CAP_BPS / BPS;
    }

    /// @notice Tokens `wallet` bought from the pool during its window.
    function boughtDuringWindow(PoolId poolId, address wallet) external view returns (uint256) {
        return _pools[poolId].bought[wallet];
    }

    /// @notice ETH collected for the pool's buybacks, in wei (ETH held here plus `jarClaims`).
    function jar(PoolId poolId) external view returns (uint256) {
        return _pools[poolId].jar;
    }

    /// @notice Part of the pool's jar held as ERC-6909 ETH claims on the PoolManager.
    function jarClaims(PoolId poolId) external view returns (uint256) {
        return _pools[poolId].jarClaims;
    }

    /// @notice Timestamp before which swaps on the pool skip the automatic buyback attempt.
    function nextAutoBuybackAt(PoolId poolId) external view returns (uint256) {
        return _pools[poolId].nextAutoBuybackAt;
    }

    /// @notice The reference sqrt price a buyback in the current block is bounded by, and when it was recorded.
    /// A zero `recordedAt` or one older than the current block means the next interaction records a fresh one.
    function referencePrice(PoolId poolId) external view returns (uint160 sqrtPriceX96, uint256 recordedAt) {
        PoolState storage p = _pools[poolId];
        return (p.referenceSqrtPriceX96, p.referenceAt);
    }

    /// @notice The sqrt price limit a buyback would use right now.
    function buybackSqrtPriceLimit(PoolId poolId) external view returns (uint160) {
        PoolState storage p = _pool(poolId);
        uint160 anchor = p.referenceSqrtPriceX96;
        if (p.referenceAt != block.timestamp) (anchor,,,) = poolManager.getSlot0(poolId);
        return _buybackLimit(anchor);
    }

    /// @notice Fee preview for a fully filled swap in which ETH is the specified amount.
    /// @param amountSpecified Negative for an exact-input buy (ETH in), positive for an exact-output sell (ETH out).
    function quoteSpecifiedEthFees(int256 amountSpecified) external pure returns (uint256 fee, uint256 jarCut) {
        return _feesForSpecifiedEth(amountSpecified);
    }

    // ---------------------------------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------------------------------

    function _pool(PoolId poolId) private view returns (PoolState storage p) {
        p = _pools[poolId];
        if (!p.initialized) revert UnknownPool();
    }

    function _key(PoolState storage p) private view returns (PoolKey memory) {
        return PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: p.token,
            fee: p.fee,
            tickSpacing: p.tickSpacing,
            hooks: IHooks(address(this))
        });
    }

    /// @dev The buy cap reads the token's `totalSupply()` on every buy during the window; refuse a pool whose
    /// token cannot answer it, so that its buys do not revert for ten minutes.
    function _requireSupplyReadable(Currency token) private view {
        (bool ok, bytes memory ret) =
            Currency.unwrap(token).staticcall(abi.encodeWithSelector(IPoolToken.totalSupply.selector));
        if (!ok || ret.length < 32) revert TokenSupplyUnavailable();
    }

    /// @dev Record the pool's price at the hook's first interaction in this block. Buybacks in the block may not
    /// push the price more than the band below it, so a trade in the same block cannot move the price first and
    /// have the jar buy at the moved price.
    function _touchReference(PoolId poolId, PoolState storage p) private {
        if (p.referenceAt == block.timestamp) return;
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        p.referenceSqrtPriceX96 = sqrtPriceX96;
        p.referenceAt = uint64(block.timestamp);
    }

    function _buybackLimit(uint160 referenceSqrtPriceX96) private pure returns (uint160) {
        uint256 limit = uint256(referenceSqrtPriceX96) * (BPS - BUYBACK_SQRT_PRICE_BAND_BPS) / BPS;
        if (limit <= TickMath.MIN_SQRT_PRICE) return TickMath.MIN_SQRT_PRICE + 1;
        return uint160(limit);
    }

    /// @dev ETH is currency0. It is the specified currency for exact-input buys and exact-output sells.
    function _ethIsSpecified(SwapParams calldata params) private pure returns (bool) {
        return params.zeroForOne == (params.amountSpecified < 0);
    }

    /// @dev Run the swap the PoolManager is about to run (the request adjusted by the full-fill fee, exactly as
    /// the PoolManager adjusts it) and revert it, returning the ETH it moved. A fill stopped early by the
    /// swapper's price limit or by liquidity moves the same ETH whatever the request, so the fee computed from it
    /// matches the real swap.
    function _simulateEthSide(PoolKey calldata key, SwapParams calldata params, uint256 fullFees)
        private
        returns (uint256)
    {
        SwapParams memory sim = SwapParams({
            zeroForOne: params.zeroForOne,
            amountSpecified: params.amountSpecified + int256(fullFees),
            sqrtPriceLimitX96: params.sqrtPriceLimitX96
        });
        try this.simulateSwap(key, sim) {
            revert SimulationDidNotRevert();
        } catch (bytes memory reason) {
            if (reason.length == 36 && bytes4(reason) == SimulationResult.selector) {
                int256 raw;
                assembly ("memory-safe") {
                    raw := mload(add(reason, 36))
                }
                int128 eth = BalanceDelta.wrap(raw).amount0();
                return eth < 0 ? uint256(uint128(-eth)) : uint256(uint128(eth));
            }
            // Anything else (price limit already exceeded, no liquidity, ...) is the swap's own error.
            assembly ("memory-safe") {
                revert(add(reason, 32), mload(reason))
            }
        }
    }

    /// @dev Fees for a swap in which ETH is specified, from the ETH side the pool really moves. A full fill pays
    /// the quote on the request; a partial fill pays 1% + 1% of the gross ETH side of what was filled.
    function _specifiedEthFees(int256 amountSpecified, uint256 realised)
        private
        pure
        returns (uint256 fee, uint256 jarCut)
    {
        (fee, jarCut) = _feesForSpecifiedEth(amountSpecified);
        uint256 full = fee + jarCut;
        if (amountSpecified < 0) {
            // Exact-input buy: the pool receives the request less the fees when fully filled.
            if (realised >= uint256(-amountSpecified) - full) return (fee, jarCut);
            (uint256 partialFee, uint256 partialJar) = _feesFromNet(realised);
            return (partialFee < fee ? partialFee : fee, partialJar < jarCut ? partialJar : jarCut);
        }
        // Exact-output sell: the pool pays the request plus the fees when fully filled.
        if (realised >= uint256(amountSpecified) + full) return (fee, jarCut);
        return _feesFromGross(realised);
    }

    function _feesForSpecifiedEth(int256 amountSpecified) private pure returns (uint256 fee, uint256 jarCut) {
        if (amountSpecified < 0) {
            // Exact-input buy: the trader sends the gross ETH amount.
            return _feesFromGross(uint256(-amountSpecified));
        }
        // Exact-output sell: the trader must receive the net amount after the fees.
        return _feesFromNet(uint256(amountSpecified));
    }

    /// @dev Fees on a known gross ETH amount: 1% each.
    function _feesFromGross(uint256 gross) private pure returns (uint256 fee, uint256 jarCut) {
        fee = gross * FEE_BPS / BPS;
        jarCut = gross * JAR_BPS / BPS;
    }

    /// @dev Fees on a net ETH amount: gross it up so that each share is 1% of the gross, rounding against the trader.
    function _feesFromNet(uint256 net) private pure returns (uint256 fee, uint256 jarCut) {
        uint256 gross = (net * BPS + (BPS - FEE_BPS - JAR_BPS) - 1) / (BPS - FEE_BPS - JAR_BPS);
        return _feesFromGross(gross);
    }

    function _enforceBuyCap(PoolId poolId, PoolState storage p, int128 tokensOut) private {
        if (tokensOut <= 0 || block.timestamp >= p.windowEndsAt) return;
        uint256 cap = buyCap(poolId);
        address wallet = tx.origin;
        uint256 total = p.bought[wallet] + uint256(uint128(tokensOut));
        if (total > cap) revert BuyCapExceeded(wallet, total, cap);
        p.bought[wallet] = total;
    }

    /// @dev Settle the fee to the recipient and the jar cut to this contract, in ETH when the PoolManager can pay,
    /// otherwise as ERC-6909 claims held here. The PoolManager credits the hook's delta after the callback returns.
    function _collect(PoolId poolId, PoolState storage p, uint256 fee, uint256 jarCut) private {
        if (fee > 0) {
            try poolManager.take(CurrencyLibrary.ADDRESS_ZERO, feeRecipient, fee) {
                emit FeePaid(poolId, feeRecipient, fee);
            } catch {
                poolManager.mint(address(this), CurrencyLibrary.ADDRESS_ZERO.toId(), fee);
                pendingFees += fee;
                emit FeeClaimMinted(poolId, fee);
            }
        }
        if (jarCut > 0) {
            try poolManager.take(CurrencyLibrary.ADDRESS_ZERO, address(this), jarCut) {
                emit JarFunded(poolId, jarCut, false);
            } catch {
                poolManager.mint(address(this), CurrencyLibrary.ADDRESS_ZERO.toId(), jarCut);
                p.jarClaims += jarCut;
                emit JarFunded(poolId, jarCut, true);
            }
            p.jar += jarCut;
        }
    }

    /// @dev Runs inside an unlock. Spends the jar on an exact-input buy bounded by the block's price band, pays
    /// with claims first and ETH second, takes the tokens and burns them (or keeps them here when the token
    /// cannot burn). Whatever the band left unspent stays in the jar.
    function _executeBuyback(PoolId poolId) private {
        PoolState storage p = _pool(poolId);
        uint256 amount = p.jar;
        if (amount < BUYBACK_THRESHOLD) revert JarBelowThreshold(amount, BUYBACK_THRESHOLD);
        // A synced ERC-20 would make a native settle revert and resetting it would break the outer caller.
        if (!poolManager.getSyncedCurrency().isAddressZero()) revert CurrencySynced();

        _touchReference(poolId, p);
        uint160 limit = _buybackLimit(p.referenceSqrtPriceX96);
        (uint160 current,,,) = poolManager.getSlot0(poolId);
        if (limit >= current) revert BuybackPriceOutOfBand(current, limit);

        BalanceDelta delta = poolManager.swap(
            _key(p), SwapParams({zeroForOne: true, amountSpecified: -amount.toInt256(), sqrtPriceLimitX96: limit}), ""
        );
        uint256 spent = uint256(uint128(-delta.amount0()));
        uint256 bought = uint256(uint128(delta.amount1()));
        if (bought == 0) revert BuybackBoughtNothing();
        p.jar = amount - spent;

        uint256 fromClaims = p.jarClaims < spent ? p.jarClaims : spent;
        if (fromClaims > 0) {
            p.jarClaims -= fromClaims;
            poolManager.burn(address(this), CurrencyLibrary.ADDRESS_ZERO.toId(), fromClaims);
        }
        uint256 fromBalance = spent - fromClaims;
        if (fromBalance > 0) poolManager.settle{value: fromBalance}();

        poolManager.take(p.token, address(this), bought);
        bool burned = _burn(p.token, bought);
        emit Buyback(poolId, spent, bought, burned);
    }

    /// @dev Offer the whole balance of the token held here (this purchase plus anything an earlier burn refused)
    /// to the token's `burn(uint256)`. What it does not destroy stays here until the next buyback tries again.
    function _burn(Currency currency, uint256 bought) private returns (bool burned) {
        IPoolToken token = IPoolToken(Currency.unwrap(currency));
        uint256 held = token.balanceOf(address(this));
        try token.burn(held) {} catch {}
        uint256 left = token.balanceOf(address(this));
        uint256 destroyed = left < held ? held - left : 0;
        if (destroyed > 0) tokensBurned[Currency.unwrap(currency)] += destroyed;
        tokensLocked[Currency.unwrap(currency)] = left;
        burned = destroyed >= bought;
    }
}
