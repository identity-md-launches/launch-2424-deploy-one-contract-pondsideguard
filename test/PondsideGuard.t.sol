// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {Pool} from "v4-core/libraries/Pool.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/types/PoolOperation.sol";
import {PondsideGuard} from "../src/PondsideGuard.sol";
import {PondsideGuardDeployer} from "../src/PondsideGuardDeployer.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {CustomRevert} from "v4-core/libraries/CustomRevert.sol";
import {PondsideFixture, BurnableToken, PlainToken, NoSupplyToken, TogglingRecipient} from "./utils/Fixtures.sol";

contract PondsideGuardRegistrationTest is PondsideFixture {
    using PoolIdLibrary for PoolKey;

    function test_registersPoolWithoutOpeningWindow() public view {
        assertTrue(hook.isPool(poolId));
        assertEq(hook.poolToken(poolId), address(token));
        assertEq(hook.windowEndsAt(poolId), 0, "window opens with the first swap");
        assertTrue(hook.windowOpen(poolId), "cap is in force until the window has run");
        assertEq(hook.buyCap(poolId), TOKEN_SUPPLY / 100);
        assertEq(hook.jar(poolId), 0);
        assertFalse(hook.paused());
        PoolKey memory stored = hook.poolKey(poolId);
        assertEq(Currency.unwrap(stored.currency0), address(0));
        assertEq(Currency.unwrap(stored.currency1), address(token));
        assertEq(stored.fee, LP_FEE);
        assertEq(stored.tickSpacing, TICK_SPACING);
        assertEq(address(stored.hooks), address(hook));
    }

    function test_firstSwapOpensWindow() public {
        vm.expectEmit(true, false, false, true, address(hook));
        emit PondsideGuard.WindowOpened(poolId, block.timestamp + 10 minutes);
        buyExactIn(alice, 1 ether);
        assertEq(hook.windowEndsAt(poolId), block.timestamp + 10 minutes);
        vm.warp(block.timestamp + 5 minutes);
        buyExactIn(alice, 1 ether);
        assertEq(hook.windowEndsAt(poolId), block.timestamp + 5 minutes, "window end does not move");
    }

    function test_windowStartsAtFirstSwapNotAtInitialization() public {
        // Liquidity arrives an hour after an (anyone's) initialize: the first buyer is still capped.
        vm.warp(block.timestamp + 1 hours);
        uint256 cap = hook.buyCap(poolId);
        vm.startPrank(alice, alice);
        vm.expectRevert(
            wrapped(
                hook,
                IHooks.afterSwap.selector,
                abi.encodeWithSelector(PondsideGuard.BuyCapExceeded.selector, alice, cap + 1, cap)
            )
        );
        swapRouter.swap{value: 20_000 ether}(
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: int256(cap + 1), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopPrank();
        assertEq(hook.windowEndsAt(poolId), 0, "a reverted first swap does not open the window");
    }

    /// @dev A pool with no liquidity accepts swaps that fill nothing. Such a swap must not start the window,
    /// or a stranger could expire the cap before trading really opens.
    function test_swapThatMovesNothingDoesNotOpenWindow() public {
        // A fresh pool on a fresh hook, initialized but without liquidity.
        token = new BurnableToken();
        token.mint(lp, TOKEN_SUPPLY);
        (deployer, hook) = deployHook(recipient);
        key = poolKeyFor(address(token), hook);
        poolId = key.toId();
        manager.initialize(key, SQRT_PRICE_1_1);
        address griefer = makeAddr("griefer");
        vm.deal(griefer, 10 ether);

        // A 1-wei buy (no fee, no simulation) and a 1-ether buy (simulated, fills nothing) both succeed, as
        // does a sell request the empty pool cannot fill. (An empty pool's price slides to each swap's limit,
        // so the limits stay next to 1:1 for the liquidity added below.)
        buyExactInLimited(griefer, 1, SQRT_PRICE_1_1 - 1);
        buyExactInLimited(griefer, 1 ether, SQRT_PRICE_1_1 - 2);
        sellExactOutLimited(griefer, 1 ether, SQRT_PRICE_1_1);
        assertEq(token.balanceOf(griefer), 0, "nothing moved");
        assertEq(currentSqrtPrice(), SQRT_PRICE_1_1);
        assertEq(hook.windowEndsAt(poolId), 0, "an empty swap does not open the window");
        assertTrue(hook.windowOpen(poolId), "the cap is still pending");
        assertEq(hook.jar(poolId), 0);

        // Liquidity arrives ten minutes later: the first real buyer is still capped.
        vm.warp(block.timestamp + 10 minutes);
        addFullRangeLiquidity(lp, POOL_LIQUIDITY);
        uint256 cap = hook.buyCap(poolId);
        vm.startPrank(alice, alice);
        vm.expectRevert(
            wrapped(
                hook,
                IHooks.afterSwap.selector,
                abi.encodeWithSelector(PondsideGuard.BuyCapExceeded.selector, alice, cap * 5, cap)
            )
        );
        swapRouter.swap{value: 20_000 ether}(
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: int256(cap * 5), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopPrank();
        assertEq(hook.windowEndsAt(poolId), 0, "a reverted swap does not open the window");

        // The first filled swap opens the window and is itself counted against the cap.
        vm.expectEmit(true, false, false, true, address(hook));
        emit PondsideGuard.WindowOpened(poolId, block.timestamp + 10 minutes);
        buyExactOut(alice, cap, 20_000 ether);
        assertEq(hook.windowEndsAt(poolId), block.timestamp + 10 minutes);
        assertEq(hook.boughtDuringWindow(poolId, alice), cap);
        vm.expectRevert();
        buyExactOut(alice, 1, 1 ether);
    }

    function test_firstFilledSellOpensWindowToo() public {
        vm.startPrank(lp, lp);
        token.transfer(alice, 10 ether);
        vm.stopPrank();
        vm.expectEmit(true, false, false, true, address(hook));
        emit PondsideGuard.WindowOpened(poolId, block.timestamp + 10 minutes);
        sellExactIn(alice, 10 ether);
        assertEq(hook.windowEndsAt(poolId), block.timestamp + 10 minutes);
        assertEq(hook.boughtDuringWindow(poolId, alice), 0, "a sell is not a buy");
    }

    function test_secondPoolRegistersWithItsOwnState() public {
        BurnableToken other = new BurnableToken();
        other.mint(lp, TOKEN_SUPPLY);
        PoolKey memory otherKey = poolKeyFor(address(other), hook);
        PoolId otherId = otherKey.toId();
        vm.expectEmit(true, false, false, true, address(hook));
        emit PondsideGuard.PoolRegistered(otherId, Currency.wrap(address(other)), LP_FEE, TICK_SPACING);
        manager.initialize(otherKey, SQRT_PRICE_1_1);
        assertTrue(hook.isPool(otherId));
        assertEq(hook.poolToken(otherId), address(other));

        // Trading on the first pool leaves the second untouched.
        buyExactIn(alice, 1 ether);
        assertEq(hook.jar(poolId), 0.01 ether);
        assertEq(hook.jar(otherId), 0);
        assertGt(hook.windowEndsAt(poolId), 0);
        assertEq(hook.windowEndsAt(otherId), 0);
        assertGt(hook.boughtDuringWindow(poolId, alice), 0);
        assertEq(hook.boughtDuringWindow(otherId, alice), 0);
    }

    function test_junkPoolInitializedFirstDoesNotBlockTheRealPool() public {
        (, PondsideGuard fresh) = deployHook(recipient);
        address griefer = makeAddr("griefer");
        vm.startPrank(griefer, griefer);
        BurnableToken junk = new BurnableToken();
        manager.initialize(poolKeyFor(address(junk), fresh), SQRT_PRICE_1_1);
        vm.stopPrank();

        BurnableToken real = new BurnableToken();
        PoolKey memory realKey = poolKeyFor(address(real), fresh);
        manager.initialize(realKey, SQRT_PRICE_1_1);
        assertTrue(fresh.isPool(realKey.toId()));
        assertTrue(fresh.isPool(poolKeyFor(address(junk), fresh).toId()));
    }

    function test_sameTokenDifferentFeeTierIsAnotherPool() public {
        PoolKey memory tierKey = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(address(token)),
            fee: 10_000,
            tickSpacing: 200,
            hooks: IHooks(address(hook))
        });
        manager.initialize(tierKey, SQRT_PRICE_1_1);
        assertTrue(hook.isPool(tierKey.toId()));
        assertEq(hook.poolKey(tierKey.toId()).fee, 10_000);
    }

    function test_poolWithoutNativeEthIsRefused() public {
        (, PondsideGuard fresh) = deployHook(recipient);
        BurnableToken a = new BurnableToken();
        BurnableToken b = new BurnableToken();
        (address lo, address hi) = address(a) < address(b) ? (address(a), address(b)) : (address(b), address(a));
        PoolKey memory badKey = PoolKey({
            currency0: Currency.wrap(lo),
            currency1: Currency.wrap(hi),
            fee: LP_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(fresh))
        });
        vm.expectRevert(
            wrapped(
                fresh,
                IHooks.afterInitialize.selector,
                abi.encodeWithSelector(PondsideGuard.PairMustBeNativeEth.selector)
            )
        );
        manager.initialize(badKey, SQRT_PRICE_1_1);
        assertFalse(fresh.isPool(badKey.toId()));
    }

    function test_tokenWithoutTotalSupplyIsRefused() public {
        NoSupplyToken bare = new NoSupplyToken();
        PoolKey memory bareKey = poolKeyFor(address(bare), hook);
        vm.expectRevert(
            wrapped(
                hook,
                IHooks.afterInitialize.selector,
                abi.encodeWithSelector(PondsideGuard.TokenSupplyUnavailable.selector)
            )
        );
        manager.initialize(bareKey, SQRT_PRICE_1_1);
        assertFalse(hook.isPool(bareKey.toId()));
    }

    function test_unknownPoolHasNoCapOrToken() public view {
        PoolId none = PoolId.wrap(keccak256("nope"));
        assertFalse(hook.isPool(none));
        assertEq(hook.buyCap(none), 0);
        assertEq(hook.poolToken(none), address(0));
        assertFalse(hook.windowOpen(none));
        assertEq(hook.jar(none), 0);
    }

    function test_unknownPoolActionsRevert() public {
        PoolId none = PoolId.wrap(keccak256("nope"));
        vm.expectRevert(PondsideGuard.UnknownPool.selector);
        hook.buyback(none);
        vm.expectRevert(PondsideGuard.UnknownPool.selector);
        hook.poolKey(none);
        vm.expectRevert(PondsideGuard.UnknownPool.selector);
        hook.buybackSqrtPriceLimit(none);
    }

    function test_hookPermissionsMatchAddress() public view {
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(
            p.afterInitialize && p.beforeSwap && p.afterSwap && p.beforeSwapReturnDelta && p.afterSwapReturnDelta
        );
        assertFalse(
            p.beforeInitialize || p.beforeAddLiquidity || p.afterAddLiquidity || p.beforeRemoveLiquidity
                || p.afterRemoveLiquidity || p.beforeDonate || p.afterDonate || p.afterAddLiquidityReturnDelta
                || p.afterRemoveLiquidityReturnDelta
        );
        assertEq(uint160(address(hook)) & Hooks.ALL_HOOK_MASK, hook.requiredFlags());
    }

    function test_unusedCallbacksRevertAndAreGated() public {
        ModifyLiquidityParams memory lpParams;
        vm.startPrank(address(manager));
        vm.expectRevert(PondsideGuard.HookNotImplemented.selector);
        hook.beforeInitialize(address(0), key, 0);
        vm.expectRevert(PondsideGuard.HookNotImplemented.selector);
        hook.beforeAddLiquidity(address(0), key, lpParams, "");
        vm.expectRevert(PondsideGuard.HookNotImplemented.selector);
        hook.beforeRemoveLiquidity(address(0), key, lpParams, "");
        vm.expectRevert(PondsideGuard.HookNotImplemented.selector);
        hook.beforeDonate(address(0), key, 0, 0, "");
        vm.expectRevert(PondsideGuard.HookNotImplemented.selector);
        hook.afterDonate(address(0), key, 0, 0, "");
        vm.stopPrank();

        SwapParams memory swapParams;
        vm.expectRevert(PondsideGuard.NotPoolManager.selector);
        hook.beforeSwap(address(0), key, swapParams, "");
        vm.expectRevert(PondsideGuard.NotPoolManager.selector);
        hook.afterSwap(address(0), key, swapParams, BalanceDelta.wrap(0), "");
        vm.expectRevert(PondsideGuard.NotPoolManager.selector);
        hook.afterInitialize(address(0), key, 0, 0);
        vm.expectRevert(PondsideGuard.NotPoolManager.selector);
        hook.unlockCallback("");
    }

    function test_selfEntryPointsOnlyFromSelf() public {
        SwapParams memory swapParams;
        vm.expectRevert(PondsideGuard.NotSelf.selector);
        hook.selfBuyback(poolId);
        vm.expectRevert(PondsideGuard.NotSelf.selector);
        hook.simulateSwap(key, swapParams);
    }

    function test_directEthIsRefused() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok,) = address(hook).call{value: 1 ether}("");
        assertFalse(ok);
        assertEq(address(hook).balance, 0);
    }

    function test_unknownUnlockActionReverts() public {
        vm.prank(address(manager));
        vm.expectRevert(abi.encodeWithSelector(PondsideGuard.UnknownAction.selector, uint8(9)));
        hook.unlockCallback(abi.encode(uint8(9), poolId));
    }
}

contract PondsideGuardFeeTest is PondsideFixture {
    function test_exactInputBuyTakesOnePercentEachFromEthIn() public {
        uint256 ethIn = 1 ether;
        uint256 aliceBefore = alice.balance;
        uint256 managerBefore = address(manager).balance;

        vm.expectEmit(true, true, false, true, address(hook));
        emit PondsideGuard.FeePaid(poolId, recipient, ethIn / 100);
        vm.expectEmit(true, false, false, true, address(hook));
        emit PondsideGuard.JarFunded(poolId, ethIn / 100, false);
        BalanceDelta delta = buyExactIn(alice, ethIn);

        assertEq(aliceBefore - alice.balance, ethIn, "trader pays exactly the input");
        assertEq(recipient.balance, ethIn / 100, "recipient fee");
        assertEq(hook.jar(poolId), ethIn / 100, "jar share");
        assertEq(address(hook).balance, ethIn / 100, "jar held as ETH");
        assertEq(hook.jarClaims(poolId), 0);
        assertEq(hook.pendingFees(), 0);
        assertEq(address(manager).balance - managerBefore, ethIn - 2 * (ethIn / 100), "pool keeps 98%");
        assertEq(uint256(uint128(-delta.amount0())), ethIn);
        assertGt(delta.amount1(), 0);
        assertEq(token.balanceOf(alice), uint256(uint128(delta.amount1())));
    }

    function test_exactOutputBuyChargesFeesOnTopOfEthNeeded() public {
        uint256 tokensOut = 1 ether;
        uint256 aliceBefore = alice.balance;
        buyExactOut(alice, tokensOut, 2 ether);

        uint256 paid = aliceBefore - alice.balance;
        uint256 fee = recipient.balance;
        assertEq(hook.jar(poolId), fee, "jar equals the recipient fee");
        uint256 poolEth = paid - 2 * fee;
        assertEq(fee, grossFromNet(poolEth) / 100, "fee is 1% of the grossed-up ETH side");
        assertEq(token.balanceOf(alice), tokensOut, "exact output honoured");
    }

    function test_exactInputSellTakesOnePercentEachFromEthOut() public {
        vm.prank(lp);
        token.transfer(alice, 10 ether);
        uint256 aliceBefore = alice.balance;
        sellExactIn(alice, 10 ether);

        uint256 received = alice.balance - aliceBefore;
        uint256 fee = recipient.balance;
        assertEq(hook.jar(poolId), fee);
        uint256 gross = received + 2 * fee;
        assertEq(fee, gross / 100, "fee is 1% of the gross ETH out");
        assertEq(token.balanceOf(alice), 0);
    }

    function test_exactOutputSellDeliversExactEthAfterFees() public {
        vm.prank(lp);
        token.transfer(alice, 10 ether);
        uint256 ethOut = 1 ether;
        uint256 aliceBefore = alice.balance;
        sellExactOut(alice, ethOut);

        assertEq(alice.balance - aliceBefore, ethOut, "trader receives exactly the requested ETH");
        uint256 fee = recipient.balance;
        assertEq(fee, grossFromNet(ethOut) / 100);
        assertEq(hook.jar(poolId), fee);
    }

    function test_feeQuoteMatchesCharges() public view {
        (uint256 fee, uint256 jarCut) = hook.quoteSpecifiedEthFees(-1 ether);
        assertEq(fee, 0.01 ether);
        assertEq(jarCut, 0.01 ether);
        (fee, jarCut) = hook.quoteSpecifiedEthFees(int256(0.98 ether));
        assertEq(fee, 0.01 ether);
        assertEq(jarCut, 0.01 ether);
    }

    function test_feesAccumulateAcrossSwapsAndBothSidesMatch() public {
        buyExactIn(alice, 1 ether);
        buyExactIn(bob, 2 ether);
        vm.prank(lp);
        token.transfer(alice, 5 ether);
        sellExactIn(alice, 5 ether);
        assertEq(hook.jar(poolId), recipient.balance, "jar and recipient always receive the same amount");
        assertEq(address(hook).balance + hook.jarClaims(poolId), hook.jar(poolId), "jar is fully backed");
    }

    function test_tinySwapRoundsFeeToZeroWithoutReverting() public {
        uint256 recipientBefore = recipient.balance;
        buyExactIn(alice, 99);
        assertEq(recipient.balance, recipientBefore);
        assertEq(hook.jar(poolId), 0);
    }
}

/// @notice ETH-specified swaps stopped early by the swapper's price limit pay 1% of the ETH that really moved.
contract PondsideGuardPartialFillTest is PondsideFixture {
    function test_partialExactInputBuyPaysFeeOnFilledEthOnly() public {
        uint256 ethIn = 1 ether;
        uint256 aliceBefore = alice.balance;
        // A limit a hair below the current price: only a sliver of the request fits.
        BalanceDelta delta = buyExactInLimited(alice, ethIn, SQRT_PRICE_1_1 - SQRT_PRICE_1_1 / 100_000_000);
        uint256 paid = aliceBefore - alice.balance;
        uint256 fee = recipient.balance;

        assertGt(delta.amount1(), 0, "something was bought");
        assertLt(paid, ethIn / 10, "far less than the request was filled");
        assertEq(uint256(uint128(-delta.amount0())), paid, "returned delta is what the trader paid");
        uint256 poolIn = paid - 2 * fee;
        assertEq(fee, grossFromNet(poolIn) / 100, "fee is 1% of the grossed-up filled ETH");
        assertEq(hook.jar(poolId), fee);
        assertLe(fee, paid / 100, "never more than 1% of what was paid");
        assertLt(fee, ethIn / 100, "far below the fee on the request");
    }

    function test_partialExactOutputSellStillReceivesEth() public {
        vm.prank(lp);
        token.transfer(alice, 10 ether);
        uint256 aliceBefore = alice.balance;
        uint256 tokensBefore = token.balanceOf(alice);
        BalanceDelta delta = sellExactOutLimited(alice, 1 ether, SQRT_PRICE_1_1 + SQRT_PRICE_1_1 / 100_000_000);

        assertLt(token.balanceOf(alice), tokensBefore, "tokens were sold");
        assertGt(delta.amount0(), 0, "trader receives ETH, never pays it");
        uint256 received = alice.balance - aliceBefore;
        assertEq(received, uint256(uint128(delta.amount0())));
        uint256 fee = recipient.balance;
        uint256 gross = received + 2 * fee;
        assertEq(fee, gross / 100, "fee is 1% of the gross ETH the pool paid");
        assertLt(received, 1 ether, "partial fill");
    }

    function test_fullFillStillPaysExactlyTheQuote() public {
        // A limit far away: the whole request is filled and the fee equals the request-based quote.
        buyExactInLimited(alice, 1 ether, TickMath.MIN_SQRT_PRICE + 1);
        assertEq(recipient.balance, 0.01 ether);
        assertEq(hook.jar(poolId), 0.01 ether);
    }

    function test_partialFillWhenLiquidityRunsOut() public {
        // Replace the full-range position by a narrow one: once a buy pushes the price below its lower tick there
        // is no liquidity left, the swap jumps to the trader's limit and most of the request stays unfilled.
        removeFullRangeLiquidity(lp, POOL_LIQUIDITY);
        vm.deal(lp, 20_000 ether);
        vm.startPrank(lp, lp);
        liquidityRouter.modifyLiquidity{value: 10_000 ether}(
            key, ModifyLiquidityParams({tickLower: -600, tickUpper: 600, liquidityDelta: 100_000 ether, salt: 0}), ""
        );
        vm.stopPrank();

        uint256 aliceBefore = alice.balance;
        BalanceDelta delta = buyExactIn(alice, 5_000 ether);
        uint256 paid = aliceBefore - alice.balance;
        uint256 fee = recipient.balance;
        assertLt(paid, 4_000 ether, "request was not fully filled");
        assertGt(paid, 1_000 ether, "but a large part was");
        assertEq(uint256(uint128(-delta.amount0())), paid);
        assertEq(fee, grossFromNet(paid - 2 * fee) / 100, "fee is 1% of the grossed-up filled ETH");
        assertEq(hook.jar(poolId), fee, "no buyback could run against an empty book");
    }

    function test_priceLimitAlreadyExceededBubblesFromSimulation() public {
        vm.startPrank(alice, alice);
        vm.expectRevert(
            wrapped(
                hook,
                IHooks.beforeSwap.selector,
                abi.encodeWithSelector(Pool.PriceLimitAlreadyExceeded.selector, SQRT_PRICE_1_1, SQRT_PRICE_1_1 + 1)
            )
        );
        swapRouter.swap{value: 1 ether}(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: SQRT_PRICE_1_1 + 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopPrank();
    }

    function test_simulationLeavesPoolUntouchedWhenSwapReverts() public {
        // Make the real swap fail after the simulation (buy cap) and check nothing from the simulation sticks.
        uint256 cap = hook.buyCap(poolId);
        uint160 priceBefore = currentSqrtPrice();
        vm.startPrank(alice, alice);
        vm.expectRevert();
        swapRouter.swap{value: 20_000 ether}(
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: -20_000 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopPrank();
        assertEq(currentSqrtPrice(), priceBefore);
        assertEq(hook.jar(poolId), 0);
        assertEq(hook.boughtDuringWindow(poolId, alice), 0);
        assertGt(cap, 0);
    }
}

contract PondsideGuardClaimTest is PondsideFixture {
    using PoolIdLibrary for PoolKey;

    TogglingRecipient internal toggler;

    function setUp() public override {
        super.setUp();
        // Rebuild the fixture around a recipient that can refuse ETH.
        toggler = new TogglingRecipient();
        token.mint(lp, TOKEN_SUPPLY);
        (deployer, hook) = deployHook(address(toggler));
        key = poolKeyFor(address(token), hook);
        poolId = key.toId();
        manager.initialize(key, SQRT_PRICE_1_1);
        addFullRangeLiquidity(lp, POOL_LIQUIDITY);
    }

    function test_feeIsMintedAsClaimWhenRecipientRefusesEth() public {
        toggler.setAccepting(false);
        vm.expectEmit(true, false, false, true, address(hook));
        emit PondsideGuard.FeeClaimMinted(poolId, 0.01 ether);
        buyExactIn(alice, 1 ether);

        assertEq(address(toggler).balance, 0);
        assertEq(hook.pendingFees(), 0.01 ether);
        assertEq(manager.balanceOf(address(hook), 0), 0.01 ether, "claim held by the hook");
        assertEq(hook.jar(poolId), 0.01 ether, "jar still collected in ETH");
        assertEq(address(hook).balance, 0.01 ether);
    }

    function test_claimFeesPaysRecipientOnceItAccepts() public {
        toggler.setAccepting(false);
        buyExactIn(alice, 1 ether);
        buyExactIn(bob, 1 ether);
        assertEq(hook.pendingFees(), 0.02 ether);

        vm.expectRevert();
        hook.claimFees();

        toggler.setAccepting(true);
        vm.expectEmit(true, false, false, true, address(hook));
        emit PondsideGuard.FeesClaimed(address(toggler), 0.02 ether);
        vm.prank(makeAddr("anyone"));
        hook.claimFees();

        assertEq(address(toggler).balance, 0.02 ether);
        assertEq(hook.pendingFees(), 0);
        assertEq(manager.balanceOf(address(hook), 0), 0);
        vm.expectRevert(PondsideGuard.NothingToClaim.selector);
        hook.claimFees();
    }

    function test_directPaymentResumesAfterRecipientAcceptsAgain() public {
        toggler.setAccepting(false);
        buyExactIn(alice, 1 ether);
        toggler.setAccepting(true);
        buyExactIn(alice, 1 ether);
        assertEq(address(toggler).balance, 0.01 ether, "second fee paid directly");
        assertEq(hook.pendingFees(), 0.01 ether, "first fee still claimable");
    }

    function test_claimsMintedWhenPoolManagerHoldsNoEth() public {
        // Simulate a PoolManager that cannot pay out ETH at hook time (its balance is credited only when the
        // router settles after the swap).
        vm.deal(address(manager), 0);
        buyExactIn(alice, 1 ether);
        assertEq(hook.pendingFees(), 0.01 ether);
        assertEq(hook.jarClaims(poolId), 0.01 ether);
        assertEq(hook.jar(poolId), 0.01 ether);
        assertEq(address(hook).balance, 0);
        assertEq(manager.balanceOf(address(hook), 0), 0.02 ether);
        assertEq(address(manager).balance, 1 ether, "trader's ETH arrived after the hook ran");

        hook.claimFees();
        assertEq(address(toggler).balance, 0.01 ether);
    }
}

contract PondsideGuardBuyCapTest is PondsideFixture {
    uint256 internal cap;

    function setUp() public override {
        super.setUp();
        cap = hook.buyCap(poolId);
        assertEq(cap, 10_000 ether);
    }

    function test_buyUpToCapSucceedsAndIsTracked() public {
        buyExactOut(alice, cap, 20_000 ether);
        assertEq(hook.boughtDuringWindow(poolId, alice), cap);
        assertEq(token.balanceOf(alice), cap);
    }

    function test_buyAboveCapRevertsInWindow() public {
        uint256 want = cap + 1;
        vm.startPrank(alice, alice);
        vm.expectRevert(
            wrapped(
                hook,
                IHooks.afterSwap.selector,
                abi.encodeWithSelector(PondsideGuard.BuyCapExceeded.selector, alice, want, cap)
            )
        );
        swapRouter.swap{value: 20_000 ether}(
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: int256(want), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopPrank();
        assertEq(hook.boughtDuringWindow(poolId, alice), 0);
    }

    function test_capIsCumulativePerWallet() public {
        buyExactOut(alice, cap / 2, 10_000 ether);
        // Fill up to the live cap exactly (a buyback may have burned a little supply in between).
        uint256 room = hook.buyCap(poolId) - hook.boughtDuringWindow(poolId, alice);
        buyExactOut(alice, room, 10_000 ether);
        assertEq(hook.boughtDuringWindow(poolId, alice), hook.buyCap(poolId));
        vm.startPrank(alice, alice);
        vm.expectRevert();
        swapRouter.swap{value: 10 ether}(
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: -int256(1 ether), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopPrank();
        // Another wallet has its own allowance.
        buyExactIn(bob, 1 ether);
        assertGt(hook.boughtDuringWindow(poolId, bob), 0);
    }

    function test_exactInputBuyIsCountedByTokensReceived() public {
        BalanceDelta delta = buyExactIn(alice, 1 ether);
        assertEq(hook.boughtDuringWindow(poolId, alice), uint256(uint128(delta.amount1())));
    }

    function test_sellsAreNotCapped() public {
        vm.prank(lp);
        token.transfer(alice, 50_000 ether);
        sellExactIn(alice, 50_000 ether);
        assertEq(hook.boughtDuringWindow(poolId, alice), 0);
    }

    function test_capLiftsWhenWindowEnds() public {
        buyExactIn(bob, 99); // opens the window
        vm.warp(hook.windowEndsAt(poolId));
        assertFalse(hook.windowOpen(poolId));
        buyExactOut(alice, cap + 1, 20_000 ether);
        assertEq(hook.boughtDuringWindow(poolId, alice), 0, "nothing tracked after the window");
    }

    function test_capAppliesUntilTheLastSecond() public {
        buyExactIn(bob, 99); // opens the window
        vm.warp(hook.windowEndsAt(poolId) - 1);
        assertTrue(hook.windowOpen(poolId));
        vm.startPrank(alice, alice);
        vm.expectRevert();
        swapRouter.swap{value: 20_000 ether}(
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: int256(cap + 1), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopPrank();
    }

    function test_capFollowsLiveTotalSupply() public {
        vm.prank(lp);
        token.burn(TOKEN_SUPPLY / 2);
        assertEq(hook.buyCap(poolId), cap / 2);
    }
}

contract PondsideGuardBuybackTest is PondsideFixture {
    using PoolIdLibrary for PoolKey;

    function test_buybackRevertsBelowThreshold() public {
        buyExactIn(alice, 1 ether);
        assertEq(hook.jar(poolId), 0.01 ether);
        vm.expectRevert(abi.encodeWithSelector(PondsideGuard.JarBelowThreshold.selector, 0.01 ether, 0.1 ether));
        hook.buyback(poolId);
    }

    function test_swapFillingTheJarTriggersBuybackAndBurn() public {
        uint256 supplyBefore = token.totalSupply();
        buyExactIn(alice, 9 ether);
        assertEq(hook.jar(poolId), 0.09 ether);
        assertEq(token.totalSupply(), supplyBefore);

        // The tenth ETH pushes the jar to 0.1 ETH: the buyback runs inside this swap.
        buyExactIn(bob, 1 ether);
        assertEq(hook.jar(poolId), 0, "whole jar spent");
        assertEq(address(hook).balance, 0, "no ETH left behind");
        assertGt(hook.tokensBurned(address(token)), 0);
        assertEq(token.totalSupply(), supplyBefore - hook.tokensBurned(address(token)), "bought tokens were burned");
        assertEq(token.balanceOf(address(hook)), 0);
        assertEq(hook.tokensLocked(address(token)), 0);
    }

    function test_swapSucceedsWhenAutomaticBuybackFailsAndAnyoneMayRetry() public {
        buyExactIn(alice, 9 ether);
        // Make the token refuse transfers to the hook so the automatic buyback reverts inside the swap.
        token.setBlockedRecipient(address(hook));
        uint256 supplyBefore = token.totalSupply();
        vm.expectEmit(true, false, false, true, address(hook));
        emit PondsideGuard.AutoBuybackDeferred(poolId, block.timestamp + 5 minutes);
        buyExactIn(bob, 1 ether);
        assertEq(hook.jar(poolId), 0.1 ether, "jar kept when the buyback fails");
        assertEq(address(hook).balance, 0.1 ether);
        assertEq(token.totalSupply(), supplyBefore, "nothing burned");
        assertEq(hook.nextAutoBuybackAt(poolId), block.timestamp + 5 minutes);

        vm.expectRevert();
        hook.buyback(poolId);

        token.setBlockedRecipient(address(0));
        vm.prank(makeAddr("anyone"));
        hook.buyback(poolId);
        assertEq(hook.jar(poolId), 0);
        assertEq(address(hook).balance, 0);
        assertGt(hook.tokensBurned(address(token)), 0);
        assertEq(token.totalSupply(), supplyBefore - hook.tokensBurned(address(token)));
    }

    function test_failedAutomaticBuybackIsNotRetriedUntilTheDelayPasses() public {
        buyExactIn(alice, 9 ether);
        token.setBlockedRecipient(address(hook));
        buyExactIn(bob, 1 ether);
        assertEq(hook.jar(poolId), 0.1 ether);
        token.setBlockedRecipient(address(0));

        // Within the delay the swap does not attempt the buyback even though it would now succeed.
        buyExactIn(alice, 1 ether);
        assertEq(hook.jar(poolId), 0.11 ether, "no attempt during the delay");
        assertEq(hook.tokensBurned(address(token)), 0);

        // Once it passes, the next swap runs it.
        vm.warp(hook.nextAutoBuybackAt(poolId));
        buyExactIn(alice, 1 ether);
        assertEq(hook.jar(poolId), 0, "jar spent after the delay");
        assertGt(hook.tokensBurned(address(token)), 0);
    }

    function test_buybackSettlesWithClaimsWhenJarWasMintedAsClaims() public {
        vm.deal(address(manager), 0);
        buyExactIn(alice, 5 ether);
        assertEq(hook.jarClaims(poolId), 0.05 ether);
        // The manager now holds alice's 5 ETH, so the rest is collected as ETH.
        buyExactIn(alice, 4 ether);
        assertEq(hook.jar(poolId), 0.09 ether);
        assertEq(hook.jarClaims(poolId), 0.05 ether);
        assertEq(address(hook).balance, 0.04 ether);

        buyExactIn(bob, 1 ether);
        assertEq(hook.jar(poolId), 0);
        assertEq(hook.jarClaims(poolId), 0);
        assertEq(address(hook).balance, 0);
        assertEq(manager.balanceOf(address(hook), 0), hook.pendingFees(), "only recipient claims remain");
        assertGt(hook.tokensBurned(address(token)), 0);
    }

    function test_buybackKeepsTokensThatCannotBurn() public {
        PlainToken plain = new PlainToken();
        plain.mint(lp, TOKEN_SUPPLY);
        (, PondsideGuard plainHook) = deployHook(recipient);
        PoolKey memory plainKey = poolKeyFor(address(plain), plainHook);
        PoolId plainId = plainKey.toId();
        manager.initialize(plainKey, SQRT_PRICE_1_1);

        vm.deal(lp, 600_000 ether);
        vm.startPrank(lp, lp);
        plain.approve(address(liquidityRouter), type(uint256).max);
        liquidityRouter.modifyLiquidity{value: 500_001 ether}(
            plainKey,
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(TICK_SPACING),
                tickUpper: TickMath.maxUsableTick(TICK_SPACING),
                liquidityDelta: int256(uint256(POOL_LIQUIDITY)),
                salt: 0
            }),
            ""
        );
        vm.stopPrank();

        vm.startPrank(alice, alice);
        swapRouter.swap{value: 10 ether}(
            plainKey,
            SwapParams({
                zeroForOne: true, amountSpecified: -int256(10 ether), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopPrank();

        assertEq(plainHook.jar(plainId), 0);
        assertGt(plainHook.tokensLocked(address(plain)), 0);
        assertEq(plainHook.tokensBurned(address(plain)), 0);
        assertEq(plain.balanceOf(address(plainHook)), plainHook.tokensLocked(address(plain)), "tokens stay in the hook");
    }

    function test_temporarilyUnburnableTokensAreBurnedAtTheNextBuyback() public {
        token.setBurnDisabled(true);
        vm.expectEmit(true, false, false, false, address(hook));
        emit PondsideGuard.Buyback(poolId, 0, 0, false);
        buyExactIn(alice, 10 ether);
        uint256 locked = hook.tokensLocked(address(token));
        assertGt(locked, 0, "burn refused: tokens held");
        assertEq(token.balanceOf(address(hook)), locked);
        assertEq(hook.jar(poolId), 0, "jar was spent");

        token.setBurnDisabled(false);
        uint256 supplyBefore = token.totalSupply();
        buyExactIn(alice, 10 ether);
        assertEq(hook.tokensLocked(address(token)), 0, "earlier tokens burned with the new ones");
        assertEq(token.balanceOf(address(hook)), 0);
        assertEq(hook.tokensBurned(address(token)), supplyBefore - token.totalSupply());
        assertGt(hook.tokensBurned(address(token)), locked);
    }

    function test_buybackEmitsAndIsCallerAgnostic() public {
        buyExactIn(alice, 9 ether);
        token.setBlockedRecipient(address(hook));
        buyExactIn(bob, 1 ether);
        token.setBlockedRecipient(address(0));

        vm.expectEmit(true, false, false, false, address(hook));
        emit PondsideGuard.Buyback(poolId, 0.1 ether, 0, true);
        vm.prank(bob);
        hook.buyback(poolId);
    }

    function test_buybackRevertsWhilePaused() public {
        buyExactIn(alice, 9 ether);
        token.setBlockedRecipient(address(hook));
        buyExactIn(bob, 1 ether);
        token.setBlockedRecipient(address(0));
        vm.prank(owner);
        hook.pause();
        vm.expectRevert(PondsideGuard.SwapsPaused.selector);
        hook.buyback(poolId);
    }

    function test_buybackSwapIsNotChargedFeesOrCapped() public {
        uint256 recipientBefore = recipient.balance;
        buyExactIn(alice, 9 ether);
        uint256 afterNine = recipient.balance;
        buyExactIn(bob, 1 ether);
        assertEq(recipient.balance - afterNine, 0.01 ether, "only bob's swap paid a fee");
        assertEq(recipient.balance - recipientBefore, 0.1 ether);
        assertEq(hook.boughtDuringWindow(poolId, address(hook)), 0);
    }

    function test_jarsAreIndependentPerPool() public {
        BurnableToken other = new BurnableToken();
        other.mint(lp, TOKEN_SUPPLY);
        PoolKey memory otherKey = poolKeyFor(address(other), hook);
        PoolId otherId = otherKey.toId();
        manager.initialize(otherKey, SQRT_PRICE_1_1);
        buyExactIn(alice, 10 ether);
        assertEq(hook.jar(poolId), 0, "first pool's buyback ran");
        assertEq(hook.jar(otherId), 0);
        vm.expectRevert(abi.encodeWithSelector(PondsideGuard.JarBelowThreshold.selector, 0, 0.1 ether));
        hook.buyback(otherId);
    }
}

/// @notice The buyback may not push the price more than the band below the block's opening price.
contract PondsideGuardBuybackBandTest is PondsideFixture {
    function setUp() public override {
        super.setUp();
        // A thin pool, so that a 1 ETH buy moves the price a lot. Fill the jar to just under the threshold with a
        // round trip that leaves the price near 1:1, so that bob's next 1 ETH buy tips it over.
        removeFullRangeLiquidity(lp, POOL_LIQUIDITY - 2e18);
        BalanceDelta delta = buyExactIn(alice, 5 ether);
        sellExactIn(alice, uint256(uint128(delta.amount1())));
        assertGt(hook.jar(poolId), 0.09 ether);
        assertLt(hook.jar(poolId), 0.1 ether);
        assertEq(hook.tokensBurned(address(token)), 0);
        assertEq(hook.nextAutoBuybackAt(poolId), 0, "no automatic attempt yet");
    }

    function _nextBlock() internal {
        vm.warp(block.timestamp + 1);
        vm.roll(block.number + 1);
    }

    function test_sameBlockSandwichCannotMakeTheJarBuyAtTheMovedPrice() public {
        _nextBlock();
        uint160 opening = currentSqrtPrice();
        uint256 bobEthBefore = bob.balance;
        // bob's buy tips the jar over the threshold and moves the price well past the band.
        BalanceDelta delta = buyExactIn(bob, 1 ether);
        assertGe(hook.jar(poolId), 0.1 ether, "automatic attempt was refused, jar kept");
        assertEq(hook.tokensBurned(address(token)), 0);
        assertLt(currentSqrtPrice(), opening * 99 / 100);
        (uint160 recorded, uint256 at) = hook.referencePrice(poolId);
        assertEq(recorded, opening);
        assertEq(at, block.timestamp);

        // Calling buyback() in the same block is refused with the out-of-band error.
        uint160 limit = hook.buybackSqrtPriceLimit(poolId);
        vm.expectRevert(abi.encodeWithSelector(PondsideGuard.BuybackPriceOutOfBand.selector, currentSqrtPrice(), limit));
        vm.prank(bob);
        hook.buyback(poolId);

        // Selling back loses money: there was no jar purchase to sandwich.
        sellExactIn(bob, uint256(uint128(delta.amount1())));
        assertLt(bob.balance, bobEthBefore, "round trip through the hook fee loses");
    }

    function test_nextBlockBuybackIsBoundedByTheBandAndKeepsTheRemainder() public {
        _nextBlock();
        buyExactIn(bob, 1 ether);
        uint256 jarBefore = hook.jar(poolId);
        assertGe(jarBefore, 0.1 ether);

        _nextBlock();
        uint160 opening = currentSqrtPrice();
        uint160 limit = hook.buybackSqrtPriceLimit(poolId);
        assertEq(limit, opening * 99 / 100);
        vm.prank(makeAddr("anyone"));
        hook.buyback(poolId);
        assertEq(currentSqrtPrice(), limit, "stopped exactly at the band");
        assertGt(hook.jar(poolId), 0, "unspent remainder stays in the jar");
        assertLt(hook.jar(poolId), jarBefore, "some of the jar was spent");
        assertGt(hook.tokensBurned(address(token)), 0);
        assertEq(address(hook).balance + hook.jarClaims(poolId), hook.jar(poolId), "jar fully backed");

        // The remainder waits: here it is below the threshold again, and even a jar above it could not buy more
        // in this block because the price already sits at the band.
        uint256 remainder = hook.jar(poolId);
        if (remainder >= 0.1 ether) {
            vm.expectRevert(abi.encodeWithSelector(PondsideGuard.BuybackPriceOutOfBand.selector, limit, limit));
        } else {
            vm.expectRevert(abi.encodeWithSelector(PondsideGuard.JarBelowThreshold.selector, remainder, 0.1 ether));
        }
        hook.buyback(poolId);
    }

    function test_liquidityPullDoesNotLetTheJarBeDrainedAtAnyPrice() public {
        _nextBlock();
        buyExactIn(bob, 1 ether);
        _nextBlock();
        // The LP pulls almost everything and calls buyback: the band stops the buy after a sliver of ETH.
        removeFullRangeLiquidity(lp, 2e18 - 1e16);
        uint256 jarBefore = hook.jar(poolId);
        vm.prank(lp);
        hook.buyback(poolId);
        uint256 spent = jarBefore - hook.jar(poolId);
        assertLt(spent, jarBefore / 50, "the thinned book absorbs only a sliver before the band");
    }

    function test_deepPoolSpendsWholeJarWithinTheBand() public {
        vm.deal(lp, 600_000 ether);
        vm.startPrank(lp, lp);
        liquidityRouter.modifyLiquidity{value: 600_000 ether}(
            key,
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(TICK_SPACING),
                tickUpper: TickMath.maxUsableTick(TICK_SPACING),
                liquidityDelta: int256(uint256(POOL_LIQUIDITY)),
                salt: 0
            }),
            ""
        );
        vm.stopPrank();
        _nextBlock();
        buyExactIn(bob, 1 ether);
        assertEq(hook.jar(poolId), 0, "0.1 ETH is far inside the band of a deep pool");
        assertGt(hook.tokensBurned(address(token)), 0);
    }
}

contract PondsideGuardPauseTest is PondsideFixture {
    function test_onlyOwnerPausesAndUnpauses() public {
        vm.prank(alice);
        vm.expectRevert(PondsideGuard.NotOwner.selector);
        hook.pause();
        vm.prank(owner);
        hook.pause();
        vm.prank(alice);
        vm.expectRevert(PondsideGuard.NotOwner.selector);
        hook.unpause();
        vm.prank(owner);
        hook.unpause();
    }

    function test_pauseAndUnpauseAreIdempotentGuards() public {
        vm.startPrank(owner);
        vm.expectRevert(PondsideGuard.NotPaused.selector);
        hook.unpause();
        vm.expectEmit(true, false, false, true, address(hook));
        emit PondsideGuard.Paused(owner);
        hook.pause();
        vm.expectRevert(PondsideGuard.AlreadyPaused.selector);
        hook.pause();
        vm.expectEmit(true, false, false, true, address(hook));
        emit PondsideGuard.Unpaused(owner);
        hook.unpause();
        vm.stopPrank();
    }

    function test_swapsRevertWhilePausedAndResumeAfter() public {
        vm.prank(owner);
        hook.pause();
        assertTrue(hook.paused());

        vm.startPrank(alice, alice);
        vm.expectRevert(
            wrapped(hook, IHooks.beforeSwap.selector, abi.encodeWithSelector(PondsideGuard.SwapsPaused.selector))
        );
        swapRouter.swap{value: 1 ether}(
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: -int256(1 ether), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopPrank();

        vm.prank(lp);
        token.transfer(alice, 1 ether);
        vm.startPrank(alice, alice);
        vm.expectRevert();
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: false, amountSpecified: -int256(1 ether), sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopPrank();

        vm.prank(owner);
        hook.unpause();
        buyExactIn(alice, 1 ether);
        assertEq(recipient.balance, 0.01 ether);
    }

    function test_liquidityCanBeRemovedAndAddedWhilePaused() public {
        vm.prank(owner);
        hook.pause();
        uint256 lpEthBefore = lp.balance;
        uint256 lpTokenBefore = token.balanceOf(lp);
        removeFullRangeLiquidity(lp, POOL_LIQUIDITY / 2);
        assertGt(lp.balance, lpEthBefore);
        assertGt(token.balanceOf(lp), lpTokenBefore);
        addFullRangeLiquidity(lp, POOL_LIQUIDITY / 4);
    }

    function test_ownerHasNoOtherPowers() public {
        // The owner cannot move fees, the jar, or the pool: the only owner-gated functions are pause/unpause.
        vm.startPrank(owner);
        vm.expectRevert(PondsideGuard.NotSelf.selector);
        hook.selfBuyback(poolId);
        vm.expectRevert(PondsideGuard.NotPoolManager.selector);
        hook.unlockCallback(abi.encode(uint8(1), poolId));
        vm.stopPrank();
        assertEq(hook.owner(), owner);
        assertEq(deployer.owner(), owner);
    }
}

contract PondsideGuardFuzzTest is PondsideFixture {
    /// @dev Over any mix of swaps, the jar is fully backed, both fee streams match, and the trader never pays
    /// more than the gross ETH side.
    function testFuzz_feeAccountingHolds(uint96 ethIn, uint96 tokensIn, uint96 ethOut) public {
        ethIn = uint96(bound(ethIn, 1, 4 ether));
        tokensIn = uint96(bound(tokensIn, 1, 4 ether));
        ethOut = uint96(bound(ethOut, 1, 1 ether));
        vm.prank(lp);
        token.transfer(alice, 100 ether);

        uint256 recipientBefore = recipient.balance;
        buyExactIn(alice, ethIn);
        uint256 afterBuy = recipient.balance - recipientBefore;
        assertEq(afterBuy, uint256(ethIn) / 100);
        assertEq(hook.jar(poolId), afterBuy);

        sellExactIn(alice, tokensIn);
        sellExactOut(alice, ethOut);

        assertEq(hook.jar(poolId), recipient.balance - recipientBefore, "jar mirrors recipient fees");
        assertEq(address(hook).balance + hook.jarClaims(poolId), hook.jar(poolId), "jar fully backed");
        assertLt(hook.jar(poolId), 0.1 ether, "below threshold, no buyback ran");
    }

    /// @dev For any price limit between the current price and the floor, an exact-input buy pays 1% + 1% of the
    /// grossed-up ETH that actually entered the pool, and never more than 1% of what the trader paid.
    function testFuzz_partialBuyFeeFollowsRealisedEth(uint96 ethIn, uint32 limitBps) public {
        ethIn = uint96(bound(ethIn, 1e12, 9 ether)); // keeps the jar below the buyback threshold
        limitBps = uint32(bound(limitBps, 1, 9_999));
        uint160 limit = uint160(uint256(SQRT_PRICE_1_1) * limitBps / 10_000);
        if (limit <= TickMath.MIN_SQRT_PRICE) limit = TickMath.MIN_SQRT_PRICE + 1;
        uint256 aliceBefore = alice.balance;
        BalanceDelta delta = buyExactInLimited(alice, ethIn, limit);
        uint256 paid = aliceBefore - alice.balance;
        uint256 fee = recipient.balance;
        assertEq(uint256(uint128(-delta.amount0())), paid);
        assertEq(hook.jar(poolId), fee);
        assertLe(paid, ethIn);
        if (paid == ethIn) {
            assertEq(fee, uint256(ethIn) / 100, "full fill pays the quote");
        } else {
            assertEq(fee, grossFromNet(paid - 2 * fee) / 100, "partial fill pays on the filled ETH");
        }
        assertLe(fee, paid / 100);
    }

    function testFuzz_netGrossUpChargesOnePercentOfTheGrossedUpSide(uint128 net) public view {
        net = uint128(bound(net, 1, type(uint96).max));
        (uint256 fee, uint256 jarCut) = hook.quoteSpecifiedEthFees(int256(uint256(net)));
        uint256 gross = grossFromNet(net);
        assertEq(fee, jarCut);
        assertEq(fee, gross / 100);
        // The trader's net plus both fees never exceeds the grossed-up amount and falls short of it by at most
        // the two rounding remainders.
        assertLe(net + fee + jarCut, gross);
        assertLt(gross - (net + fee + jarCut), 200);
    }

    function testFuzz_buyCapHoldsForAnyWalletAndAmount(address wallet, uint96 amount) public {
        assumeNotZeroAddress(wallet);
        assumeNotPrecompile(wallet);
        assumeNotForgeAddress(wallet);
        vm.assume(wallet.code.length == 0);
        amount = uint96(bound(amount, 1, 20_000 ether));
        vm.deal(wallet, 50_000 ether);
        uint256 cap = hook.buyCap(poolId);
        vm.startPrank(wallet, wallet);
        if (amount > cap) vm.expectRevert();
        swapRouter.swap{value: 40_000 ether}(
            key,
            SwapParams({
                zeroForOne: true,
                amountSpecified: int256(uint256(amount)),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopPrank();
        assertEq(hook.boughtDuringWindow(poolId, wallet), amount > cap ? 0 : amount);
    }
}
