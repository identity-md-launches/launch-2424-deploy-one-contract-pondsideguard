// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/test/PoolModifyLiquidityTest.sol";
import {PondsideGuard} from "../src/PondsideGuard.sol";
import {PondsideFixture, BurnableToken, TogglingRecipient} from "./utils/Fixtures.sol";

/// @notice Drives the hook through random sequences of buys, sells, buybacks, fee claims, pauses, liquidity moves,
/// recipient refusals and time jumps over two pools, recording what the hook reported it moved.
contract PondsideGuardHandler is Test {
    using PoolIdLibrary for PoolKey;

    bytes32 internal constant FEE_PAID = keccak256("FeePaid(bytes32,address,uint256)");
    bytes32 internal constant FEE_CLAIM_MINTED = keccak256("FeeClaimMinted(bytes32,uint256)");
    bytes32 internal constant JAR_FUNDED = keccak256("JarFunded(bytes32,uint256,bool)");
    bytes32 internal constant BUYBACK = keccak256("Buyback(bytes32,uint256,uint256,bool)");

    PoolManager internal manager;
    PoolSwapTest internal swapRouter;
    PoolModifyLiquidityTest internal liquidityRouter;
    PondsideGuard public hook;
    TogglingRecipient public recipient;
    address internal owner;
    address internal lp;

    PoolKey[2] internal keys;
    BurnableToken[2] public tokens;
    address[3] public actors;

    // Ghosts, per pool where it matters.
    uint256 public ghostFeesReported; // FeePaid + FeeClaimMinted
    uint256 public ghostFeesPaidDirect; // FeePaid only
    uint256[2] public ghostJarFunded;
    uint256[2] public ghostJarSpent;
    uint256[2] public ghostTokensBoughtBack;
    uint256 public ghostRecipientReceived;
    uint256 public ghostSwapsWhilePaused;
    uint256 public ghostCapViolations;
    uint256 public ghostFeeMismatches;
    uint256 public ghostSwaps;
    uint256 public ghostBuybacks;
    uint256 public ghostClaims;
    uint256 internal liquidityAdds;
    mapping(uint256 pool => mapping(address wallet => uint256)) public ghostBoughtInWindow;
    uint256[2] public initialCap;

    struct Setup {
        PoolManager manager;
        PoolSwapTest swapRouter;
        PoolModifyLiquidityTest liquidityRouter;
        PondsideGuard hook;
        TogglingRecipient recipient;
        address owner;
        address lp;
    }

    constructor(Setup memory s, PoolKey[2] memory keys_, BurnableToken[2] memory tokens_) {
        manager = s.manager;
        swapRouter = s.swapRouter;
        liquidityRouter = s.liquidityRouter;
        hook = s.hook;
        recipient = s.recipient;
        owner = s.owner;
        lp = s.lp;
        PondsideGuard hook_ = s.hook;
        PoolSwapTest swapRouter_ = s.swapRouter;
        keys[0] = keys_[0];
        keys[1] = keys_[1];
        tokens = tokens_;
        actors = [makeAddr("inv-alice"), makeAddr("inv-bob"), makeAddr("inv-carol")];
        for (uint256 a; a < 3; ++a) {
            vm.deal(actors[a], 1_000 ether);
            for (uint256 i; i < 2; ++i) {
                vm.prank(actors[a], actors[a]);
                tokens_[i].approve(address(swapRouter_), type(uint256).max);
            }
        }
        for (uint256 i; i < 2; ++i) {
            initialCap[i] = hook_.buyCap(keys_[i].toId());
        }
    }

    function poolId(uint256 i) public view returns (PoolId) {
        return keys[i].toId();
    }

    // ------------------------------------------------------------------ actions

    function buyExactIn(uint256 actorSeed, uint256 poolSeed, uint256 ethIn) external {
        (address actor, uint256 p) = _pick(actorSeed, poolSeed);
        ethIn = bound(ethIn, 1, 20 ether);
        _swap(actor, p, true, -int256(ethIn), ethIn);
    }

    function buyExactOut(uint256 actorSeed, uint256 poolSeed, uint256 tokensOut) external {
        (address actor, uint256 p) = _pick(actorSeed, poolSeed);
        tokensOut = bound(tokensOut, 1, 15_000 ether);
        _swap(actor, p, true, int256(tokensOut), tokensOut * 2 + 1 ether);
    }

    function sellExactIn(uint256 actorSeed, uint256 poolSeed, uint256 tokensIn) external {
        (address actor, uint256 p) = _pick(actorSeed, poolSeed);
        uint256 held = tokens[p].balanceOf(actor);
        if (held == 0) return;
        tokensIn = bound(tokensIn, 1, held);
        _swap(actor, p, false, -int256(tokensIn), 0);
    }

    function sellExactOut(uint256 actorSeed, uint256 poolSeed, uint256 ethOut) external {
        (address actor, uint256 p) = _pick(actorSeed, poolSeed);
        uint256 held = tokens[p].balanceOf(actor);
        if (held < 1 ether) return;
        ethOut = bound(ethOut, 1, held / 2);
        _swap(actor, p, false, int256(ethOut), 0);
    }

    function buyback(uint256 callerSeed, uint256 poolSeed) external {
        (address caller, uint256 p) = _pick(callerSeed, poolSeed);
        vm.recordLogs();
        vm.prank(caller, caller);
        try hook.buyback(poolId(p)) {
            ++ghostBuybacks;
            _consumeLogs(0, false);
        } catch {
            vm.getRecordedLogs();
        }
    }

    function claimFees(uint256 callerSeed) external {
        (address caller,) = _pick(callerSeed, 0);
        uint256 before = address(recipient).balance;
        uint256 pending = hook.pendingFees();
        vm.prank(caller, caller);
        try hook.claimFees() {
            ++ghostClaims;
            assertEq(address(recipient).balance - before, pending, "claimFees pays exactly the pending claims");
            ghostRecipientReceived += pending;
        } catch {}
    }

    function setRecipientAccepting(bool accepting) external {
        recipient.setAccepting(accepting);
    }

    function togglePause(uint256 callerSeed) external {
        // A random non-owner first: it must never succeed.
        (address stranger,) = _pick(callerSeed, 0);
        bool wasPaused = hook.paused();
        vm.prank(stranger);
        try hook.pause() {
            revert("stranger paused");
        } catch {}
        vm.prank(stranger);
        try hook.unpause() {
            revert("stranger unpaused");
        } catch {}
        assertEq(hook.paused(), wasPaused);
        vm.prank(owner);
        if (wasPaused) hook.unpause();
        else hook.pause();
    }

    function moveLiquidity(uint256 poolSeed, uint256 amount, bool add) external {
        uint256 p = poolSeed % 2;
        amount = bound(amount, 1 ether, 50_000 ether);
        vm.deal(lp, lp.balance + amount * 4 + 1 ether);
        vm.startPrank(lp, lp);
        try liquidityRouter.modifyLiquidity{value: add ? amount * 4 + 1 ether : 0}(
            keys[p],
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(keys[p].tickSpacing),
                tickUpper: TickMath.maxUsableTick(keys[p].tickSpacing),
                liquidityDelta: add ? int256(amount) : -int256(amount),
                // Fresh positions for adds (the test router rejects topping up a position with accrued fees);
                // removals draw on the setUp position.
                salt: add ? bytes32(++liquidityAdds) : bytes32(0)
            }),
            ""
        ) {}
        catch {
            // Removing more than is deposited reverts in the PoolManager itself, never because of the hook.
            assertFalse(add, "adding liquidity is never blocked");
        }
        vm.stopPrank();
    }

    function warp(uint256 secs) external {
        secs = bound(secs, 1, 15 minutes);
        vm.warp(block.timestamp + secs);
        vm.roll(block.number + 1);
    }

    // ------------------------------------------------------------------ internals

    function _pick(uint256 actorSeed, uint256 poolSeed) internal view returns (address, uint256) {
        return (actors[actorSeed % 3], poolSeed % 2);
    }

    struct Pre {
        bool paused;
        bool inWindow;
        uint256 boughtBefore;
        uint256 capBefore;
        uint256 recipientBefore;
    }

    function _pre(address actor, PoolId id) internal view returns (Pre memory pre) {
        pre.paused = hook.paused();
        pre.boughtBefore = hook.boughtDuringWindow(id, actor);
        pre.capBefore = hook.buyCap(id);
        uint256 windowEnds = hook.windowEndsAt(id);
        pre.inWindow = windowEnds == 0 || block.timestamp < windowEnds;
        pre.recipientBefore = address(recipient).balance;
    }

    function _swap(address actor, uint256 p, bool zeroForOne, int256 amountSpecified, uint256 value) internal {
        Pre memory pre = _pre(actor, poolId(p));
        vm.deal(actor, actor.balance + value);
        vm.recordLogs();
        vm.startPrank(actor, actor);
        try swapRouter.swap{value: value}(
            keys[p],
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        ) returns (
            BalanceDelta delta
        ) {
            vm.stopPrank();
            _afterSwap(actor, p, zeroForOne, delta, pre);
        } catch {
            vm.stopPrank();
            vm.getRecordedLogs();
        }
    }

    function _afterSwap(address actor, uint256 p, bool zeroForOne, BalanceDelta delta, Pre memory pre) internal {
        ++ghostSwaps;
        if (pre.paused) ++ghostSwapsWhilePaused;
        if (zeroForOne && pre.inWindow) {
            uint256 got = uint256(uint128(delta.amount1()));
            ghostBoughtInWindow[p][actor] += got;
            if (pre.boughtBefore + got > pre.capBefore) ++ghostCapViolations;
            if (ghostBoughtInWindow[p][actor] > initialCap[p]) ++ghostCapViolations;
        }
        ghostRecipientReceived += address(recipient).balance - pre.recipientBefore;
        _consumeLogs(p, true);
    }

    /// @dev Sum what the hook reported. In a swap the fee and the jar cut must be equal (1% each).
    function _consumeLogs(uint256 p, bool isSwap) internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 fee;
        uint256 jarIn;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(hook)) continue;
            bytes32 t = logs[i].topics[0];
            uint256 pool = PoolId.unwrap(poolId(0)) == logs[i].topics[1] ? 0 : 1;
            if (t == FEE_PAID) {
                uint256 amount = abi.decode(logs[i].data, (uint256));
                fee += amount;
                ghostFeesPaidDirect += amount;
            } else if (t == FEE_CLAIM_MINTED) {
                fee += abi.decode(logs[i].data, (uint256));
            } else if (t == JAR_FUNDED) {
                (uint256 amount,) = abi.decode(logs[i].data, (uint256, bool));
                jarIn += amount;
                ghostJarFunded[pool] += amount;
            } else if (t == BUYBACK) {
                (uint256 spent, uint256 bought,) = abi.decode(logs[i].data, (uint256, uint256, bool));
                ghostJarSpent[pool] += spent;
                ghostTokensBoughtBack[pool] += bought;
            }
        }
        ghostFeesReported += fee;
        if (isSwap && fee != jarIn) ++ghostFeeMismatches;
        p;
    }
}

contract PondsideGuardInvariantTest is PondsideFixture {
    using PoolIdLibrary for PoolKey;

    PondsideGuardHandler internal handler;
    TogglingRecipient internal toggler;
    BurnableToken internal token2;
    PoolKey internal key2;
    uint256 internal constant SUPPLY_EACH = 1_000_000 ether;

    function setUp() public override {
        super.setUp();
        // Rebuild around a recipient that can refuse ETH, with two pools on the same hook.
        toggler = new TogglingRecipient();
        (deployer, hook) = deployHook(address(toggler));
        token = new BurnableToken();
        token.mint(lp, SUPPLY_EACH);
        token2 = new BurnableToken();
        token2.mint(lp, SUPPLY_EACH);

        key = poolKeyFor(address(token), hook);
        poolId = key.toId();
        manager.initialize(key, SQRT_PRICE_1_1);
        addFullRangeLiquidity(lp, 200_000 ether);

        key2 = poolKeyFor(address(token2), hook);
        manager.initialize(key2, SQRT_PRICE_1_1);
        vm.deal(lp, lp.balance + 100_001 ether);
        vm.startPrank(lp, lp);
        token2.approve(address(liquidityRouter), type(uint256).max);
        liquidityRouter.modifyLiquidity{value: 100_001 ether}(
            key2,
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(TICK_SPACING),
                tickUpper: TickMath.maxUsableTick(TICK_SPACING),
                liquidityDelta: int256(100_000 ether),
                salt: 0
            }),
            ""
        );
        vm.stopPrank();

        handler = new PondsideGuardHandler(
            PondsideGuardHandler.Setup(manager, swapRouter, liquidityRouter, hook, toggler, owner, lp),
            [key, key2],
            [token, token2]
        );
        targetContract(address(handler));
        excludeSender(address(hook));
        excludeSender(address(manager));
    }

    function _jar(uint256 i) internal view returns (uint256) {
        return hook.jar(handler.poolId(i));
    }

    function _jarClaims(uint256 i) internal view returns (uint256) {
        return hook.jarClaims(handler.poolId(i));
    }

    /// @dev The hook holds exactly what it owes: ETH for the jars' ETH parts, ERC-6909 claims for pending fees plus
    /// the jars' claim parts. Nothing leaks out and nothing is stranded.
    /// forge-config: default.invariant.runs = 48
    /// forge-config: default.invariant.depth = 40
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_hookHoldingsEqualWhatItOwes() public view {
        uint256 jars = _jar(0) + _jar(1);
        uint256 claims = _jarClaims(0) + _jarClaims(1);
        assertLe(_jarClaims(0), _jar(0));
        assertLe(_jarClaims(1), _jar(1));
        assertEq(address(hook).balance, jars - claims, "ETH held == ETH part of the jars");
        assertEq(manager.balanceOf(address(hook), 0), hook.pendingFees() + claims, "claims held == owed claims");
    }

    /// @dev Each jar equals everything ever put in it minus everything its buybacks spent.
    /// forge-config: default.invariant.runs = 48
    /// forge-config: default.invariant.depth = 40
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_jarIsFundedMinusSpent() public view {
        for (uint256 i; i < 2; ++i) {
            assertEq(_jar(i), handler.ghostJarFunded(i) - handler.ghostJarSpent(i), "jar conservation");
        }
    }

    /// @dev Every fee the hook took reached the recipient or is still owed to it as a claim, and fee == jar cut.
    /// forge-config: default.invariant.runs = 48
    /// forge-config: default.invariant.depth = 40
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_feesReachRecipientOrAreOwed() public view {
        assertEq(handler.ghostRecipientReceived() + hook.pendingFees(), handler.ghostFeesReported(), "fee conservation");
        assertEq(handler.ghostFeesReported(), handler.ghostJarFunded(0) + handler.ghostJarFunded(1), "fee == jar");
        assertEq(handler.ghostFeeMismatches(), 0, "a swap paid a fee different from its jar cut");
        assertEq(address(toggler).balance, handler.ghostRecipientReceived(), "recipient got nothing else");
    }

    /// @dev Bought-back tokens are destroyed: supply falls by exactly what the hook burned, and it keeps none.
    /// forge-config: default.invariant.runs = 48
    /// forge-config: default.invariant.depth = 40
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_boughtBackTokensAreBurned() public view {
        BurnableToken[2] memory ts = [token, token2];
        for (uint256 i; i < 2; ++i) {
            assertEq(hook.tokensBurned(address(ts[i])), handler.ghostTokensBoughtBack(i), "every buyback burned");
            assertEq(ts[i].totalSupply(), SUPPLY_EACH - hook.tokensBurned(address(ts[i])), "supply only burns");
            assertEq(ts[i].balanceOf(address(hook)), 0, "hook keeps no tokens");
            assertEq(hook.tokensLocked(address(ts[i])), 0);
        }
    }

    /// @dev No wallet ever buys more than 1% of supply in a pool's window, and no swap ever succeeds while paused.
    /// forge-config: default.invariant.runs = 48
    /// forge-config: default.invariant.depth = 40
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_capAndPauseAreNeverBypassed() public view {
        assertEq(handler.ghostCapViolations(), 0, "buy cap bypassed");
        assertEq(handler.ghostSwapsWhilePaused(), 0, "swap succeeded while paused");
        for (uint256 i; i < 2; ++i) {
            for (uint256 a; a < 3; ++a) {
                assertLe(hook.boughtDuringWindow(handler.poolId(i), handler.actors(a)), handler.initialCap(i));
            }
        }
    }

    /// @dev The configuration cannot change: there is no admin path besides pause.
    /// forge-config: default.invariant.runs = 48
    /// forge-config: default.invariant.depth = 40
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_configurationIsFixed() public view {
        assertEq(hook.owner(), owner);
        assertEq(hook.feeRecipient(), address(toggler));
        assertEq(address(hook.poolManager()), address(manager));
    }
}
