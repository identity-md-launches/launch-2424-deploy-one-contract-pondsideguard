// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {PondsideGuard} from "../src/PondsideGuard.sol";
import {PondsideFixture, BurnableToken, TogglingRecipient} from "./utils/Fixtures.sol";

/// @notice A hostile pool token: when the hook takes it during a buyback it tries to re-enter the hook to spend
/// another pool's jar and to redirect the fee claims. It swallows the failures so the buyback itself completes.
contract ReentrantToken {
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    PondsideGuard public target;
    PoolId public victim;
    bool public reentered;
    bool public buybackReentrySucceeded;
    bool public claimReentrySucceeded;

    function arm(PondsideGuard target_, PoolId victim_) external {
        target = target_;
        victim = victim_;
    }

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
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
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        if (address(target) != address(0) && to == address(target)) {
            reentered = true;
            try target.buyback(victim) {
                buybackReentrySucceeded = true;
            } catch {}
            try target.claimFees() {
                claimReentrySucceeded = true;
            } catch {}
        }
        _transfer(msg.sender, to, amount);
        return true;
    }
}

/// @notice A router that leaves an ERC-20 synced on the PoolManager while it swaps, which makes the hook's native
/// settle impossible inside that swap. It buys with ETH, exact input.
contract SyncingRouter is IUnlockCallback {
    IPoolManager internal immutable manager;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function buy(PoolKey calldata key, uint256 ethIn) external payable returns (BalanceDelta delta) {
        delta = abi.decode(manager.unlock(abi.encode(key, ethIn, msg.sender)), (BalanceDelta));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (PoolKey memory key, uint256 ethIn, address payer) = abi.decode(data, (PoolKey, uint256, address));
        manager.sync(key.currency1);
        BalanceDelta delta = manager.swap(
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: -int256(ethIn), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            ""
        );
        // Close the token sync with nothing paid, then pay the ETH and take the tokens.
        manager.settle();
        manager.settle{value: uint256(uint128(-delta.amount0()))}();
        manager.take(key.currency1, payer, uint256(uint128(delta.amount1())));
        return abi.encode(delta);
    }

    receive() external payable {}
}

contract PondsideGuardAdversarialTest is PondsideFixture {
    using PoolIdLibrary for PoolKey;

    // ------------------------------------------------------------------ access control

    /// forge-config: default.fuzz.runs = 256
    function testFuzz_onlyTheOwnerCanPauseOrUnpause(address caller) public {
        vm.assume(caller != owner);
        vm.prank(caller);
        vm.expectRevert(PondsideGuard.NotOwner.selector);
        hook.pause();

        vm.prank(owner);
        hook.pause();
        vm.prank(caller);
        vm.expectRevert(PondsideGuard.NotOwner.selector);
        hook.unpause();
        assertTrue(hook.paused(), "stranger could not unpause");
    }

    /// forge-config: default.fuzz.runs = 256
    function testFuzz_hookCallbacksRejectAnyoneButThePoolManager(address caller) public {
        vm.assume(caller != address(manager));
        SwapParams memory params =
            SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1});
        vm.startPrank(caller);
        vm.expectRevert(PondsideGuard.NotPoolManager.selector);
        hook.beforeSwap(caller, key, params, "");
        vm.expectRevert(PondsideGuard.NotPoolManager.selector);
        hook.afterSwap(caller, key, params, BalanceDelta.wrap(0), "");
        vm.expectRevert(PondsideGuard.NotPoolManager.selector);
        hook.afterInitialize(caller, key, SQRT_PRICE_1_1, 0);
        vm.expectRevert(PondsideGuard.NotPoolManager.selector);
        hook.unlockCallback(abi.encode(uint8(1), poolId));
        vm.stopPrank();
    }

    function test_forgedClaimCallbackCannotPayAnyoneElse() public {
        // Even the owner cannot drive the claim path outside an unlock, so fees cannot be redirected.
        vm.prank(owner);
        vm.expectRevert(PondsideGuard.NotPoolManager.selector);
        hook.unlockCallback(abi.encode(uint8(1), poolId));
    }

    // ------------------------------------------------------------------ same call twice

    function test_claimFeesWithNothingPendingReverts() public {
        buyExactIn(alice, 1 ether); // paid directly, nothing pending
        assertEq(hook.pendingFees(), 0);
        vm.expectRevert(PondsideGuard.NothingToClaim.selector);
        hook.claimFees();
    }

    function test_buybackTwiceInARowSecondFindsAnEmptyJar() public {
        // Fill the jar while the automatic buyback cannot take the token, then buy back by hand.
        token.setBlockedRecipient(address(hook));
        buyExactIn(alice, 10 ether);
        token.setBlockedRecipient(address(0));
        assertEq(hook.jar(poolId), 0.1 ether);

        hook.buyback(poolId);
        assertEq(hook.jar(poolId), 0);
        vm.expectRevert(abi.encodeWithSelector(PondsideGuard.JarBelowThreshold.selector, 0, 0.1 ether));
        hook.buyback(poolId);
    }

    function test_buybackOneWeiBelowThresholdReverts() public {
        // 9.99...ETH exact-input buy puts 1 wei less than 0.1 ETH in the jar.
        buyExactIn(alice, 10 ether - 100);
        assertEq(hook.jar(poolId), 0.1 ether - 1);
        assertEq(hook.tokensBurned(address(token)), 0, "no automatic buyback below the threshold");
        vm.expectRevert(abi.encodeWithSelector(PondsideGuard.JarBelowThreshold.selector, 0.1 ether - 1, 0.1 ether));
        hook.buyback(poolId);
    }

    // ------------------------------------------------------------------ fee rounding edges

    function test_feeRoundingBoundaryAtOneHundredWei() public {
        buyExactIn(alice, 99);
        assertEq(recipient.balance, 0, "99 wei pays no fee");
        assertEq(hook.jar(poolId), 0);
        buyExactIn(alice, 100);
        assertEq(recipient.balance, 1, "100 wei pays 1 wei");
        assertEq(hook.jar(poolId), 1);
    }

    /// forge-config: default.fuzz.runs = 256
    function testFuzz_exactInputBuyFeeIsOnePercentEachAndTraderPaysOnlyEthIn(uint256 ethIn) public {
        ethIn = bound(ethIn, 1, 50 ether);
        uint256 aliceBefore = alice.balance;
        uint256 jarBefore = hook.jar(poolId);
        uint256 burnedBefore = hook.tokensBurned(address(token));
        buyExactIn(alice, ethIn);
        assertEq(aliceBefore - alice.balance, ethIn, "trader pays exactly the ETH specified");
        assertEq(recipient.balance, ethIn / 100, "fee is 1% of the ETH side, rounded down");
        if (hook.tokensBurned(address(token)) == burnedBefore) {
            assertEq(hook.jar(poolId) - jarBefore, ethIn / 100, "jar cut is 1% of the ETH side");
        }
    }

    // ------------------------------------------------------------------ claims and pause interplay

    function test_feeClaimsStayRedeemableWhilePaused() public {
        TogglingRecipient toggler = new TogglingRecipient();
        (, PondsideGuard h) = deployHook(address(toggler));
        PoolKey memory k = poolKeyFor(address(token), h);
        manager.initialize(k, SQRT_PRICE_1_1);
        key = k;
        poolId = k.toId();
        addFullRangeLiquidity(lp, 100_000 ether);

        toggler.setAccepting(false);
        buyExactIn(alice, 2 ether);
        assertEq(h.pendingFees(), 0.02 ether);

        // A refusing recipient makes the claim revert and leaves it intact.
        vm.expectRevert();
        h.claimFees();
        assertEq(h.pendingFees(), 0.02 ether);
        assertEq(manager.balanceOf(address(h), 0), 0.02 ether);

        vm.prank(owner);
        h.pause();
        toggler.setAccepting(true);
        vm.prank(makeAddr("anyone"));
        h.claimFees();
        assertEq(address(toggler).balance, 0.02 ether, "pause does not lock the recipient's fees");
        assertEq(h.pendingFees(), 0);
        assertEq(manager.balanceOf(address(h), 0), 0);
    }

    function test_pauseDoesNotStopTheWindowClock() public {
        buyExactIn(alice, 1 ether);
        uint256 ends = hook.windowEndsAt(poolId);
        vm.prank(owner);
        hook.pause();
        vm.warp(ends);
        vm.prank(owner);
        hook.unpause();
        assertEq(hook.windowEndsAt(poolId), ends, "window is not extended by a pause");
        // After the window, a buy above the cap goes through.
        uint256 cap = hook.buyCap(poolId);
        buyExactOut(bob, cap + 1 ether, 50_000 ether);
        assertEq(token.balanceOf(bob), cap + 1 ether);
    }

    // ------------------------------------------------------------------ buy cap identity

    function test_capIsPerWalletAcrossRouters() public {
        PoolSwapTest otherRouter = new PoolSwapTest(manager);
        uint256 cap = hook.buyCap(poolId);
        buyExactOut(alice, cap - 1 ether, 50_000 ether);

        // Switching to another router (another msg.sender to the PoolManager) does not reset alice's allowance.
        vm.startPrank(alice, alice);
        vm.expectRevert();
        otherRouter.swap{value: 10 ether}(
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: int256(2 ether), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopPrank();
        assertEq(hook.boughtDuringWindow(poolId, alice), cap - 1 ether);

        // Another wallet still has its own full allowance.
        buyExactOut(bob, cap, 50_000 ether);
        assertEq(hook.boughtDuringWindow(poolId, bob), cap);
    }

    function test_selfBuybackIsNotACapBypass() public {
        // The public entry points that swap on the pool belong to the hook; a trader cannot call them to buy.
        vm.prank(alice, alice);
        vm.expectRevert(PondsideGuard.NotSelf.selector);
        hook.selfBuyback(poolId);
        SwapParams memory params = SwapParams({
            zeroForOne: true, amountSpecified: -int256(1_000 ether), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });
        vm.prank(alice, alice);
        vm.expectRevert(PondsideGuard.NotSelf.selector);
        hook.simulateSwap(key, params);
    }

    // ------------------------------------------------------------------ hostile token / other pools

    function test_hostileTokenCannotReenterToSpendAnotherPoolsJarOrClaims() public {
        // Victim pool: fill its jar but keep it under the threshold.
        buyExactIn(alice, 9 ether);
        uint256 victimJar = hook.jar(poolId);
        assertEq(victimJar, 0.09 ether);

        // Attacker's pool on the same hook with a re-entrant token.
        ReentrantToken evil = new ReentrantToken();
        evil.mint(lp, TOKEN_SUPPLY);
        PoolKey memory evilKey = poolKeyFor(address(evil), hook);
        manager.initialize(evilKey, SQRT_PRICE_1_1);
        vm.deal(lp, lp.balance + 100_001 ether);
        vm.startPrank(lp, lp);
        evil.approve(address(liquidityRouter), type(uint256).max);
        liquidityRouter.modifyLiquidity{value: 100_001 ether}(
            evilKey,
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(TICK_SPACING),
                tickUpper: TickMath.maxUsableTick(TICK_SPACING),
                liquidityDelta: int256(100_000 ether),
                salt: 0
            }),
            ""
        );
        vm.stopPrank();
        evil.arm(hook, poolId);

        // A buy on the evil pool fills its jar and triggers its buyback, which takes the evil token.
        key = evilKey;
        buyExactIn(bob, 10 ether);

        assertTrue(evil.reentered(), "the token did try to re-enter");
        assertFalse(evil.buybackReentrySucceeded(), "re-entry could not run another pool's buyback");
        assertFalse(evil.claimReentrySucceeded(), "re-entry could not claim");
        assertEq(hook.jar(poolId), victimJar, "victim jar untouched");
        assertEq(address(hook).balance, victimJar, "the victim's ETH is still held");
        assertEq(hook.jar(evilKey.toId()), 0, "the evil pool spent only its own jar");
    }

    // ------------------------------------------------------------------ the swap that fills the jar never reverts

    function test_swapFillingTheJarSucceedsWhenTheRouterLeftATokenSynced() public {
        buyExactIn(alice, 9 ether);
        SyncingRouter router = new SyncingRouter(manager);
        vm.deal(address(router), 0);

        uint256 supplyBefore = token.totalSupply();
        vm.prank(bob, bob);
        BalanceDelta delta = router.buy{value: 1 ether}(key, 1 ether);
        assertGt(delta.amount1(), 0, "bob's swap went through");
        assertEq(hook.jar(poolId), 0.1 ether, "the jar is kept when the buyback cannot settle");
        assertEq(token.totalSupply(), supplyBefore);
        assertEq(hook.nextAutoBuybackAt(poolId), block.timestamp + 5 minutes);

        // Outside that swap anyone can run it.
        hook.buyback(poolId);
        assertEq(hook.jar(poolId), 0);
        assertLt(token.totalSupply(), supplyBefore);
    }

    function test_swapFillingTheJarSucceedsWhenBurnReverts() public {
        buyExactIn(alice, 9 ether);
        token.setBurnDisabled(true);
        buyExactIn(bob, 1 ether);
        // The buyback ran but could not burn: the tokens are held, not lost, and reported.
        assertEq(hook.jar(poolId), 0);
        uint256 locked = hook.tokensLocked(address(token));
        assertGt(locked, 0);
        assertEq(token.balanceOf(address(hook)), locked);
    }

    // ------------------------------------------------------------------ unknown pools and bad input

    function test_buybackOnAPoolOfAnotherHookReverts() public {
        (, PondsideGuard other) = deployHook(recipient);
        PoolKey memory k = poolKeyFor(address(token), other);
        manager.initialize(k, SQRT_PRICE_1_1);
        // `hook` never registered that pool.
        vm.expectRevert(PondsideGuard.UnknownPool.selector);
        hook.buyback(k.toId());
        assertTrue(other.isPool(k.toId()));
        assertFalse(hook.isPool(k.toId()));
    }

    function test_exactInputBuyBeyondInt128RevertsWithoutMovingFunds() public {
        uint256 aliceBefore = alice.balance;
        vm.startPrank(alice, alice);
        vm.expectRevert();
        swapRouter.swap{value: 1 ether}(
            key,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(uint256(type(uint128).max)),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopPrank();
        assertEq(alice.balance, aliceBefore);
        assertEq(hook.jar(poolId), 0);
        assertEq(recipient.balance, 0);
    }
}
