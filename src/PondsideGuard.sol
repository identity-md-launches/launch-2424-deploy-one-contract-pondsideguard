// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {SafeCast} from "v4-core/libraries/SafeCast.sol";
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
/// @notice A standalone Uniswap v4 hook for one native-ETH / token pool. It owns no token and no pool: whoever
/// initializes the first pool with this hook on the configured PoolManager binds it. From then on the hook
///   1. takes 1% of the ETH side of every swap as a fee for `feeRecipient`, paid inside the swap (or minted as an
///      ERC-6909 claim the hook holds for the recipient when the PoolManager cannot pay it directly);
///   2. caps each wallet (`tx.origin`) at 1% of the token's total supply bought during the first 10 minutes;
///   3. takes another 1% of the ETH side into a jar and, once the jar holds at least 0.1 ETH, buys the pool's
///      token from the pool with the whole jar and burns it (automatically after the swap that filled the jar
///      when that succeeds, otherwise through `buyback()` which anyone may call);
///   4. lets `owner` pause and unpause swaps. Liquidity is never hooked, so it can always be removed.
/// @dev Liquidity and donate callbacks are not enabled. The hook's own buyback swap skips the hook callbacks,
/// which is how the PoolManager treats a swap whose caller is the pool's hook.
contract PondsideGuard is IHooks, IUnlockCallback {
    using Hooks for IHooks;
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using SafeCast for uint256;
    using SafeCast for int256;
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
    /// @notice Length of the per-wallet buy-cap window after the pool opens.
    uint256 public constant BUY_WINDOW = 10 minutes;
    /// @notice Per-wallet cap during the window, in basis points of the token's total supply (1.0%).
    uint256 public constant BUY_CAP_BPS = 100;
    /// @notice Jar balance at which a buyback may run.
    uint256 public constant BUYBACK_THRESHOLD = 0.1 ether;

    uint8 private constant ACTION_CLAIM_FEES = 1;
    uint8 private constant ACTION_BUYBACK = 2;

    // ---------------------------------------------------------------------------------------------
    // Immutable configuration
    // ---------------------------------------------------------------------------------------------

    /// @notice The Uniswap v4 PoolManager this hook serves.
    IPoolManager public immutable poolManager;
    /// @notice The only privileged account. It may pause and unpause swaps and nothing else.
    address public immutable owner;
    /// @notice Receives the 1% hook fee.
    address public immutable feeRecipient;

    // ---------------------------------------------------------------------------------------------
    // State
    // ---------------------------------------------------------------------------------------------

    /// @notice The pool bound to this hook (set by the first, and only, pool initialization).
    PoolKey public poolKey;
    /// @notice Whether a pool has been bound.
    bool public bound;
    /// @notice Timestamp at which the per-wallet buy-cap window closes (pool open time + 10 minutes).
    uint256 public windowEndsAt;
    /// @notice ETH collected for buybacks, in wei. Held as ETH in this contract plus `jarClaims`.
    uint256 public jar;
    /// @notice Part of `jar` held as ERC-6909 ETH claims on the PoolManager instead of ETH.
    uint256 public jarClaims;
    /// @notice Hook fees the PoolManager could not pay directly, held as ERC-6909 ETH claims for `feeRecipient`.
    uint256 public pendingFees;
    /// @notice Whether swaps are paused.
    bool public paused;
    /// @notice Tokens each wallet bought during the window.
    mapping(address wallet => uint256 amount) public boughtDuringWindow;
    /// @notice Tokens bought back and destroyed through the token's `burn`.
    uint256 public totalBurned;
    /// @notice Tokens bought back and locked in this contract forever because the token has no `burn`.
    uint256 public totalLocked;

    // ---------------------------------------------------------------------------------------------
    // Events and errors
    // ---------------------------------------------------------------------------------------------

    event PoolBound(PoolId indexed poolId, Currency token, uint256 windowEndsAt);
    event FeePaid(address indexed recipient, uint256 amount);
    event FeeClaimMinted(uint256 amount);
    event FeesClaimed(address indexed recipient, uint256 amount);
    event JarFunded(uint256 amount, bool asClaim);
    event Buyback(uint256 ethSpent, uint256 tokensBought, bool burned);
    event Paused(address indexed by);
    event Unpaused(address indexed by);

    error ZeroAddress();
    error NotPoolManager();
    error NotOwner();
    error NotSelf();
    error HookNotImplemented();
    error AlreadyBound();
    error PairMustBeNativeEth();
    error SwapsPaused();
    error AlreadyPaused();
    error NotPaused();
    error BuyCapExceeded(address wallet, uint256 attemptedTotal, uint256 cap);
    error JarBelowThreshold(uint256 jar, uint256 threshold);
    error BuybackBoughtNothing();
    error CurrencySynced();
    error NothingToClaim();
    error UnknownAction(uint8 action);
    error DirectEthNotAccepted();

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

    /// @notice Pause swaps. Liquidity can still be added and removed.
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
        poolManager.unlock(abi.encode(ACTION_CLAIM_FEES));
    }

    /// @notice Spend the whole jar buying the pool's token from the bound pool and burn what was bought.
    /// Anyone may call once the jar holds at least `BUYBACK_THRESHOLD`.
    function buyback() external {
        if (paused) revert SwapsPaused();
        if (jar < BUYBACK_THRESHOLD) revert JarBelowThreshold(jar, BUYBACK_THRESHOLD);
        poolManager.unlock(abi.encode(ACTION_BUYBACK));
    }

    /// @notice Internal entry point for the automatic buyback attempted inside the swap that fills the jar.
    /// Only this contract may call it; it exists so that a failing buyback can be caught without reverting
    /// the swap that triggered it.
    function selfBuyback() external {
        if (msg.sender != address(this)) revert NotSelf();
        _executeBuyback();
    }

    /// @inheritdoc IUnlockCallback
    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        uint8 action = abi.decode(data, (uint8));
        if (action == ACTION_CLAIM_FEES) {
            uint256 amount = pendingFees;
            pendingFees = 0;
            poolManager.burn(address(this), CurrencyLibrary.ADDRESS_ZERO.toId(), amount);
            poolManager.take(CurrencyLibrary.ADDRESS_ZERO, feeRecipient, amount);
            emit FeesClaimed(feeRecipient, amount);
        } else if (action == ACTION_BUYBACK) {
            _executeBuyback();
        } else {
            revert UnknownAction(action);
        }
        return "";
    }

    // ---------------------------------------------------------------------------------------------
    // Hook callbacks
    // ---------------------------------------------------------------------------------------------

    /// @inheritdoc IHooks
    function afterInitialize(address, PoolKey calldata key, uint160, int24) external onlyPoolManager returns (bytes4) {
        if (bound) revert AlreadyBound();
        if (!key.currency0.isAddressZero()) revert PairMustBeNativeEth();
        bound = true;
        poolKey = key;
        windowEndsAt = block.timestamp + BUY_WINDOW;
        emit PoolBound(key.toId(), key.currency1, windowEndsAt);
        return IHooks.afterInitialize.selector;
    }

    /// @inheritdoc IHooks
    /// @dev When ETH is the specified currency (exact-input buy, exact-output sell) the fee is charged here by
    /// returning a positive specified delta; the PoolManager credits it to the hook after the swap.
    function beforeSwap(address, PoolKey calldata, SwapParams calldata params, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (paused) revert SwapsPaused();
        int128 specified;
        if (_ethIsSpecified(params)) {
            (uint256 fee, uint256 jarCut) = _feesForSpecifiedEth(params.amountSpecified);
            specified = (fee + jarCut).toInt128();
        }
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(specified, 0), 0);
    }

    /// @inheritdoc IHooks
    /// @dev Settles both fee shares, enforces the buy cap and attempts the automatic buyback.
    function afterSwap(address, PoolKey calldata, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, int128)
    {
        uint256 fee;
        uint256 jarCut;
        int128 unspecified;
        if (_ethIsSpecified(params)) {
            (fee, jarCut) = _feesForSpecifiedEth(params.amountSpecified);
        } else {
            int128 eth = delta.amount0();
            uint256 ethSide = eth < 0 ? uint256(uint128(-eth)) : uint256(uint128(eth));
            if (params.amountSpecified < 0) {
                // Exact-input sell: the pool pays `ethSide` out, the trader receives it less the fees.
                (fee, jarCut) = _feesFromGross(ethSide);
            } else {
                // Exact-output buy: the pool needs `ethSide`, the trader pays it plus the fees.
                (fee, jarCut) = _feesFromNet(ethSide);
            }
            unspecified = (fee + jarCut).toInt128();
        }

        if (params.zeroForOne) _enforceBuyCap(delta.amount1());
        _collect(fee, jarCut);

        if (jar >= BUYBACK_THRESHOLD) {
            // The swap that fills the jar must not revert if the buyback fails.
            try this.selfBuyback() {} catch {}
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

    /// @notice The pool's token (currency1 of the bound pool), or zero before a pool is bound.
    function poolToken() public view returns (address) {
        return Currency.unwrap(poolKey.currency1);
    }

    /// @notice The maximum a wallet may buy during the window, in tokens, from the token's live total supply.
    function buyCap() public view returns (uint256) {
        if (!bound) return 0;
        return IPoolToken(poolToken()).totalSupply() * BUY_CAP_BPS / BPS;
    }

    /// @notice Whether the per-wallet buy cap is in force.
    function windowOpen() public view returns (bool) {
        return bound && block.timestamp < windowEndsAt;
    }

    /// @notice Fee preview for a swap in which ETH is the specified amount.
    /// @param amountSpecified Negative for an exact-input buy (ETH in), positive for an exact-output sell (ETH out).
    function quoteSpecifiedEthFees(int256 amountSpecified) external pure returns (uint256 fee, uint256 jarCut) {
        return _feesForSpecifiedEth(amountSpecified);
    }

    // ---------------------------------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------------------------------

    /// @dev ETH is currency0. It is the specified currency for exact-input buys and exact-output sells.
    function _ethIsSpecified(SwapParams calldata params) private pure returns (bool) {
        return params.zeroForOne == (params.amountSpecified < 0);
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

    function _enforceBuyCap(int128 tokensOut) private {
        if (tokensOut <= 0 || block.timestamp >= windowEndsAt) return;
        uint256 cap = buyCap();
        address wallet = tx.origin;
        uint256 total = boughtDuringWindow[wallet] + uint256(uint128(tokensOut));
        if (total > cap) revert BuyCapExceeded(wallet, total, cap);
        boughtDuringWindow[wallet] = total;
    }

    /// @dev Settle the fee to the recipient and the jar cut to this contract, in ETH when the PoolManager can pay,
    /// otherwise as ERC-6909 claims held here. The PoolManager credits the hook's delta after the callback returns.
    function _collect(uint256 fee, uint256 jarCut) private {
        if (fee > 0) {
            try poolManager.take(CurrencyLibrary.ADDRESS_ZERO, feeRecipient, fee) {
                emit FeePaid(feeRecipient, fee);
            } catch {
                poolManager.mint(address(this), CurrencyLibrary.ADDRESS_ZERO.toId(), fee);
                pendingFees += fee;
                emit FeeClaimMinted(fee);
            }
        }
        if (jarCut > 0) {
            try poolManager.take(CurrencyLibrary.ADDRESS_ZERO, address(this), jarCut) {
                emit JarFunded(jarCut, false);
            } catch {
                poolManager.mint(address(this), CurrencyLibrary.ADDRESS_ZERO.toId(), jarCut);
                jarClaims += jarCut;
                emit JarFunded(jarCut, true);
            }
            jar += jarCut;
        }
    }

    /// @dev Runs inside an unlock. Spends the jar on an exact-input buy, pays with claims first and ETH second,
    /// takes the tokens and burns them (or locks them here when the token cannot burn).
    function _executeBuyback() private {
        uint256 amount = jar;
        if (amount < BUYBACK_THRESHOLD) revert JarBelowThreshold(amount, BUYBACK_THRESHOLD);
        // A synced ERC-20 would make a native settle revert and resetting it would break the outer caller.
        if (!poolManager.getSyncedCurrency().isAddressZero()) revert CurrencySynced();

        BalanceDelta delta = poolManager.swap(
            poolKey,
            SwapParams({
                zeroForOne: true, amountSpecified: -amount.toInt256(), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            ""
        );
        uint256 spent = uint256(uint128(-delta.amount0()));
        uint256 bought = uint256(uint128(delta.amount1()));
        if (bought == 0) revert BuybackBoughtNothing();
        jar = amount - spent;

        uint256 fromClaims = jarClaims < spent ? jarClaims : spent;
        if (fromClaims > 0) {
            jarClaims -= fromClaims;
            poolManager.burn(address(this), CurrencyLibrary.ADDRESS_ZERO.toId(), fromClaims);
        }
        uint256 fromBalance = spent - fromClaims;
        if (fromBalance > 0) poolManager.settle{value: fromBalance}();

        poolManager.take(poolKey.currency1, address(this), bought);
        bool burned = _burn(bought);
        emit Buyback(spent, bought, burned);
    }

    /// @dev Burn through the token's `burn(uint256)`; tokens the token refuses to burn stay locked here forever.
    function _burn(uint256 amount) private returns (bool burned) {
        IPoolToken token = IPoolToken(poolToken());
        uint256 before = token.balanceOf(address(this));
        try token.burn(amount) {} catch {}
        burned = token.balanceOf(address(this)) + amount == before;
        if (burned) totalBurned += amount;
        else totalLocked += amount;
    }
}
