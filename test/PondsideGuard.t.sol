// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
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
import {PondsideFixture, BurnableToken, PlainToken, TogglingRecipient} from "./utils/Fixtures.sol";

contract PondsideGuardBindingTest is PondsideFixture {
    using PoolIdLibrary for PoolKey;

    function test_bindsFirstPoolAndOpensWindow() public view {
        assertTrue(hook.bound());
        assertEq(hook.poolToken(), address(token));
        assertEq(hook.windowEndsAt(), block.timestamp + 10 minutes);
        assertTrue(hook.windowOpen());
        assertEq(hook.buyCap(), TOKEN_SUPPLY / 100);
        assertEq(hook.jar(), 0);
        assertFalse(hook.paused());
    }

    function test_secondPoolCannotBind() public {
        BurnableToken other = new BurnableToken();
        PoolKey memory otherKey = poolKeyFor(address(other), hook);
        vm.expectRevert(
            wrapped(hook, IHooks.afterInitialize.selector, abi.encodeWithSelector(PondsideGuard.AlreadyBound.selector))
        );
        manager.initialize(otherKey, SQRT_PRICE_1_1);
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
        assertFalse(fresh.bound());
        assertEq(fresh.windowEndsAt(), 0);
    }

    function test_unboundHookHasNoCapOrToken() public {
        (, PondsideGuard fresh) = deployHook(recipient);
        assertEq(fresh.buyCap(), 0);
        assertEq(fresh.poolToken(), address(0));
        assertFalse(fresh.windowOpen());
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

    function test_selfBuybackOnlyFromSelf() public {
        vm.expectRevert(PondsideGuard.NotSelf.selector);
        hook.selfBuyback();
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
        hook.unlockCallback(abi.encode(uint8(9)));
    }
}

contract PondsideGuardFeeTest is PondsideFixture {
    function test_exactInputBuyTakesOnePercentEachFromEthIn() public {
        uint256 ethIn = 1 ether;
        uint256 aliceBefore = alice.balance;
        uint256 managerBefore = address(manager).balance;

        vm.expectEmit(true, false, false, true, address(hook));
        emit PondsideGuard.FeePaid(recipient, ethIn / 100);
        vm.expectEmit(false, false, false, true, address(hook));
        emit PondsideGuard.JarFunded(ethIn / 100, false);
        BalanceDelta delta = buyExactIn(alice, ethIn);

        assertEq(aliceBefore - alice.balance, ethIn, "trader pays exactly the input");
        assertEq(recipient.balance, ethIn / 100, "recipient fee");
        assertEq(hook.jar(), ethIn / 100, "jar share");
        assertEq(address(hook).balance, ethIn / 100, "jar held as ETH");
        assertEq(hook.jarClaims(), 0);
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
        assertEq(hook.jar(), fee, "jar equals the recipient fee");
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
        assertEq(hook.jar(), fee);
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
        assertEq(hook.jar(), fee);
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
        assertEq(hook.jar(), recipient.balance, "jar and recipient always receive the same amount");
        assertEq(address(hook).balance + hook.jarClaims(), hook.jar(), "jar is fully backed");
    }

    function test_tinySwapRoundsFeeToZeroWithoutReverting() public {
        uint256 recipientBefore = recipient.balance;
        buyExactIn(alice, 99);
        assertEq(recipient.balance, recipientBefore);
        assertEq(hook.jar(), 0);
    }
}

contract PondsideGuardClaimTest is PondsideFixture {
    TogglingRecipient internal toggler;

    function setUp() public override {
        super.setUp();
        // Rebuild the fixture around a recipient that can refuse ETH.
        toggler = new TogglingRecipient();
        token.mint(lp, TOKEN_SUPPLY);
        (deployer, hook) = deployHook(address(toggler));
        key = poolKeyFor(address(token), hook);
        manager.initialize(key, SQRT_PRICE_1_1);
        addFullRangeLiquidity(lp, POOL_LIQUIDITY);
    }

    function test_feeIsMintedAsClaimWhenRecipientRefusesEth() public {
        toggler.setAccepting(false);
        vm.expectEmit(false, false, false, true, address(hook));
        emit PondsideGuard.FeeClaimMinted(0.01 ether);
        buyExactIn(alice, 1 ether);

        assertEq(address(toggler).balance, 0);
        assertEq(hook.pendingFees(), 0.01 ether);
        assertEq(manager.balanceOf(address(hook), 0), 0.01 ether, "claim held by the hook");
        assertEq(hook.jar(), 0.01 ether, "jar still collected in ETH");
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
        assertEq(hook.jarClaims(), 0.01 ether);
        assertEq(hook.jar(), 0.01 ether);
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
        cap = hook.buyCap();
        assertEq(cap, 10_000 ether);
    }

    function test_buyUpToCapSucceedsAndIsTracked() public {
        buyExactOut(alice, cap, 20_000 ether);
        assertEq(hook.boughtDuringWindow(alice), cap);
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
        assertEq(hook.boughtDuringWindow(alice), 0);
    }

    function test_capIsCumulativePerWallet() public {
        buyExactOut(alice, cap / 2, 10_000 ether);
        // Buybacks fired by these large buys burn tokens, so the live cap shrinks slightly: stay just under it.
        buyExactOut(alice, cap / 2 - 1 ether, 10_000 ether);
        assertEq(hook.boughtDuringWindow(alice), cap - 1 ether);
        assertLt(hook.buyCap(), cap);
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
        assertGt(hook.boughtDuringWindow(bob), 0);
    }

    function test_exactInputBuyIsCountedByTokensReceived() public {
        BalanceDelta delta = buyExactIn(alice, 1 ether);
        assertEq(hook.boughtDuringWindow(alice), uint256(uint128(delta.amount1())));
    }

    function test_sellsAreNotCapped() public {
        vm.prank(lp);
        token.transfer(alice, 50_000 ether);
        sellExactIn(alice, 50_000 ether);
        assertEq(hook.boughtDuringWindow(alice), 0);
    }

    function test_capLiftsWhenWindowEnds() public {
        vm.warp(hook.windowEndsAt());
        assertFalse(hook.windowOpen());
        buyExactOut(alice, cap + 1, 20_000 ether);
        assertEq(hook.boughtDuringWindow(alice), 0, "nothing tracked after the window");
    }

    function test_capAppliesUntilTheLastSecond() public {
        vm.warp(hook.windowEndsAt() - 1);
        assertTrue(hook.windowOpen());
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
        assertEq(hook.buyCap(), cap / 2);
    }
}

contract PondsideGuardBuybackTest is PondsideFixture {
    function test_buybackRevertsBelowThreshold() public {
        buyExactIn(alice, 1 ether);
        assertEq(hook.jar(), 0.01 ether);
        vm.expectRevert(abi.encodeWithSelector(PondsideGuard.JarBelowThreshold.selector, 0.01 ether, 0.1 ether));
        hook.buyback();
    }

    function test_swapFillingTheJarTriggersBuybackAndBurn() public {
        uint256 supplyBefore = token.totalSupply();
        buyExactIn(alice, 9 ether);
        assertEq(hook.jar(), 0.09 ether);
        assertEq(token.totalSupply(), supplyBefore);

        // The tenth ETH pushes the jar to 0.1 ETH: the buyback runs inside this swap.
        buyExactIn(bob, 1 ether);
        assertEq(hook.jar(), 0, "whole jar spent");
        assertEq(address(hook).balance, 0, "no ETH left behind");
        assertGt(hook.totalBurned(), 0);
        assertEq(token.totalSupply(), supplyBefore - hook.totalBurned(), "bought tokens were burned");
        assertEq(token.balanceOf(address(hook)), 0);
        assertEq(hook.totalLocked(), 0);
    }

    function test_swapSucceedsWhenAutomaticBuybackFailsAndAnyoneMayRetry() public {
        buyExactIn(alice, 9 ether);
        // Make the token refuse transfers to the hook so the automatic buyback reverts inside the swap.
        token.setBlockedRecipient(address(hook));
        uint256 supplyBefore = token.totalSupply();
        buyExactIn(bob, 1 ether);
        assertEq(hook.jar(), 0.1 ether, "jar kept when the buyback fails");
        assertEq(address(hook).balance, 0.1 ether);
        assertEq(token.totalSupply(), supplyBefore, "nothing burned");

        vm.expectRevert();
        hook.buyback();

        token.setBlockedRecipient(address(0));
        vm.prank(makeAddr("anyone"));
        hook.buyback();
        assertEq(hook.jar(), 0);
        assertEq(address(hook).balance, 0);
        assertGt(hook.totalBurned(), 0);
        assertEq(token.totalSupply(), supplyBefore - hook.totalBurned());
    }

    function test_buybackSettlesWithClaimsWhenJarWasMintedAsClaims() public {
        vm.deal(address(manager), 0);
        buyExactIn(alice, 5 ether);
        assertEq(hook.jarClaims(), 0.05 ether);
        // The manager now holds alice's 5 ETH, so the rest is collected as ETH.
        buyExactIn(alice, 4 ether);
        assertEq(hook.jar(), 0.09 ether);
        assertEq(hook.jarClaims(), 0.05 ether);
        assertEq(address(hook).balance, 0.04 ether);

        buyExactIn(bob, 1 ether);
        assertEq(hook.jar(), 0);
        assertEq(hook.jarClaims(), 0);
        assertEq(address(hook).balance, 0);
        assertEq(manager.balanceOf(address(hook), 0), hook.pendingFees(), "only recipient claims remain");
        assertGt(hook.totalBurned(), 0);
    }

    function test_buybackLocksTokensThatCannotBurn() public {
        PlainToken plain = new PlainToken();
        plain.mint(lp, TOKEN_SUPPLY);
        (, PondsideGuard plainHook) = deployHook(recipient);
        PoolKey memory plainKey = poolKeyFor(address(plain), plainHook);
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

        assertEq(plainHook.jar(), 0);
        assertGt(plainHook.totalLocked(), 0);
        assertEq(plainHook.totalBurned(), 0);
        assertEq(plain.balanceOf(address(plainHook)), plainHook.totalLocked(), "tokens stay in the hook");
    }

    function test_buybackEmitsAndIsCallerAgnostic() public {
        buyExactIn(alice, 9 ether);
        token.setBlockedRecipient(address(hook));
        buyExactIn(bob, 1 ether);
        token.setBlockedRecipient(address(0));

        vm.expectEmit(false, false, false, false, address(hook));
        emit PondsideGuard.Buyback(0.1 ether, 0, true);
        vm.prank(bob);
        hook.buyback();
    }

    function test_buybackRevertsWhilePaused() public {
        buyExactIn(alice, 9 ether);
        token.setBlockedRecipient(address(hook));
        buyExactIn(bob, 1 ether);
        token.setBlockedRecipient(address(0));
        vm.prank(owner);
        hook.pause();
        vm.expectRevert(PondsideGuard.SwapsPaused.selector);
        hook.buyback();
    }

    function test_buybackSwapIsNotChargedFeesOrCapped() public {
        uint256 recipientBefore = recipient.balance;
        buyExactIn(alice, 9 ether);
        uint256 afterNine = recipient.balance;
        buyExactIn(bob, 1 ether);
        assertEq(recipient.balance - afterNine, 0.01 ether, "only bob's swap paid a fee");
        assertEq(recipient.balance - recipientBefore, 0.1 ether);
        assertEq(hook.boughtDuringWindow(address(hook)), 0);
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
        hook.selfBuyback();
        vm.expectRevert(PondsideGuard.NotPoolManager.selector);
        hook.unlockCallback(abi.encode(uint8(1)));
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
        assertEq(hook.jar(), afterBuy);

        sellExactIn(alice, tokensIn);
        sellExactOut(alice, ethOut);

        assertEq(hook.jar(), recipient.balance - recipientBefore, "jar mirrors recipient fees");
        assertEq(address(hook).balance + hook.jarClaims(), hook.jar(), "jar fully backed");
        assertLt(hook.jar(), 0.1 ether, "below threshold, no buyback ran");
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
        uint256 cap = hook.buyCap();
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
        assertEq(hook.boughtDuringWindow(wallet), amount > cap ? 0 : amount);
    }
}

