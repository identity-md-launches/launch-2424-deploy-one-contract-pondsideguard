// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/test/PoolModifyLiquidityTest.sol";
import {PondsideGuard} from "../../src/PondsideGuard.sol";
import {PondsideGuardDeployer} from "../../src/PondsideGuardDeployer.sol";
import {SaltMiner} from "../../script/MineSalt.s.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {CustomRevert} from "v4-core/libraries/CustomRevert.sol";

/// @notice Minimal ERC-20 with `burn`, standing in for the pool's token.
contract BurnableToken {
    string public name = "Pond Token";
    string public symbol = "POND";
    uint8 public decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    /// @dev When set, transfers to this address revert (lets tests make a buyback fail on purpose).
    address public blockedRecipient;

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
    }

    function setBlockedRecipient(address who) external {
        blockedRecipient = who;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        _transfer(from, to, amount);
        return true;
    }

    function burn(uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        totalSupply -= amount;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        require(to != blockedRecipient, "blocked");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

/// @notice ERC-20 without `burn`, to exercise the lock-forever fallback.
contract PlainToken {
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @notice Fee recipient that can refuse ETH, to exercise the claim fallback.
contract TogglingRecipient {
    bool public accepting = true;

    function setAccepting(bool value) external {
        accepting = value;
    }

    receive() external payable {
        require(accepting, "refusing ETH");
    }
}

/// @notice Shared deployment of PoolManager, routers, token, deployer and hook.
abstract contract PondsideFixture is Test {
    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint256 internal constant TOKEN_SUPPLY = 1_000_000 ether;
    uint128 internal constant POOL_LIQUIDITY = 500_000 ether;
    uint24 internal constant LP_FEE = 3000;
    int24 internal constant TICK_SPACING = 60;

    address internal owner = makeAddr("owner");
    address internal recipient = makeAddr("recipient");
    address internal lp = makeAddr("lp");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    PoolManager internal manager;
    PoolSwapTest internal swapRouter;
    PoolModifyLiquidityTest internal liquidityRouter;
    BurnableToken internal token;
    PondsideGuardDeployer internal deployer;
    PondsideGuard internal hook;
    PoolKey internal key;

    function setUp() public virtual {
        manager = new PoolManager(address(this));
        swapRouter = new PoolSwapTest(manager);
        liquidityRouter = new PoolModifyLiquidityTest(manager);
        token = new BurnableToken();
        token.mint(lp, TOKEN_SUPPLY);

        (deployer, hook) = deployHook(recipient);
        key = poolKeyFor(address(token), hook);
        manager.initialize(key, SQRT_PRICE_1_1);
        addFullRangeLiquidity(lp, POOL_LIQUIDITY);

        vm.deal(alice, 100_000 ether);
        vm.deal(bob, 100_000 ether);
        vm.startPrank(alice, alice);
        token.approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
        vm.startPrank(bob, bob);
        token.approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
    }

    function deployHook(address feeRecipient) internal returns (PondsideGuardDeployer d, PondsideGuard h) {
        d = new PondsideGuardDeployer(manager, owner, feeRecipient);
        (bytes32 salt,) = SaltMiner.mine(address(d), d.initCodeHash(), d.requiredFlags(), 0);
        h = d.deploy(salt);
    }

    function poolKeyFor(address tokenAddress, PondsideGuard h) internal pure returns (PoolKey memory) {
        return PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(tokenAddress),
            fee: LP_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(h))
        });
    }

    function addFullRangeLiquidity(address provider, uint128 liquidity) internal {
        vm.deal(provider, provider.balance + uint256(liquidity) + 1 ether);
        vm.startPrank(provider, provider);
        token.approve(address(liquidityRouter), type(uint256).max);
        liquidityRouter.modifyLiquidity{value: uint256(liquidity) + 1 ether}(
            key,
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(TICK_SPACING),
                tickUpper: TickMath.maxUsableTick(TICK_SPACING),
                liquidityDelta: int256(uint256(liquidity)),
                salt: 0
            }),
            ""
        );
        vm.stopPrank();
    }

    function removeFullRangeLiquidity(address provider, uint128 liquidity) internal {
        vm.startPrank(provider, provider);
        liquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(TICK_SPACING),
                tickUpper: TickMath.maxUsableTick(TICK_SPACING),
                liquidityDelta: -int256(uint256(liquidity)),
                salt: 0
            }),
            ""
        );
        vm.stopPrank();
    }

    /// @dev Exact-input buy: send `ethIn` wei of ETH for tokens.
    function buyExactIn(address trader, uint256 ethIn) internal returns (BalanceDelta) {
        vm.startPrank(trader, trader);
        BalanceDelta delta = swapRouter.swap{value: ethIn}(
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: -int256(ethIn), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopPrank();
        return delta;
    }

    /// @dev Exact-output buy: receive exactly `tokensOut` tokens, paying up to `maxEth`.
    function buyExactOut(address trader, uint256 tokensOut, uint256 maxEth) internal returns (BalanceDelta) {
        vm.startPrank(trader, trader);
        BalanceDelta delta = swapRouter.swap{value: maxEth}(
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: int256(tokensOut), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopPrank();
        return delta;
    }

    /// @dev Exact-input sell: send `tokensIn` tokens for ETH.
    function sellExactIn(address trader, uint256 tokensIn) internal returns (BalanceDelta) {
        vm.startPrank(trader, trader);
        BalanceDelta delta = swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: false, amountSpecified: -int256(tokensIn), sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopPrank();
        return delta;
    }

    /// @dev Exact-output sell: receive exactly `ethOut` wei of ETH.
    function sellExactOut(address trader, uint256 ethOut) internal returns (BalanceDelta) {
        vm.startPrank(trader, trader);
        BalanceDelta delta = swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: false, amountSpecified: int256(ethOut), sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopPrank();
        return delta;
    }

    /// @dev The ERC-7751 wrapper the PoolManager puts around a hook revert.
    function wrapped(PondsideGuard h, bytes4 selector, bytes memory reason) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(h),
            selector,
            reason,
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
    }

    function grossFromNet(uint256 net) internal pure returns (uint256) {
        return (net * 10_000 + 9_799) / 9_800;
    }
}
