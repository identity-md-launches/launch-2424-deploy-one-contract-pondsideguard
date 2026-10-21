# PondsideGuard — standalone Uniswap v4 hook for Robinhood Chain

`PondsideGuard` is a Uniswap v4 hook with no token and no pool of its own. Anyone may initialize a new
native-ETH / token pool with it on the Robinhood Chain PoolManager; every such pool gets its own buy-cap
window, jar and buyback, keyed by the pool's `PoolId`. Composed with The Hooks Store block builder.

| Item | Value |
| --- | --- |
| Chain | Robinhood Chain (chain id 4663) |
| PoolManager (constructor argument) | `0x8366a39CC670B4001A1121B8F6A443A643e40951` |
| Owner (pause / unpause only) | `0x5Bff2a2FEcD1d6152676813b21346238733bEAB1` (`$owner`) |
| Fee recipient ("my wallet") | `$owner` — the brief names no other wallet |
| Compiler | solc 0.8.26, EVM `cancun`, optimizer 200 runs, `bytecode_hash = "none"` |

## What the hook does

1. **Hook fee.** 1.0% of the ETH side of every buy and sell goes to `feeRecipient`. It is paid in ETH inside
   the swap that incurred it (`PoolManager.take`). If the PoolManager cannot pay it directly — the recipient
   refuses ETH, or the PoolManager's ETH balance is too low at that instant — the hook mints itself an
   ERC-6909 ETH claim and records it in `pendingFees()`. `claimFees()` redeems those claims to the recipient
   and anyone may call it. The fee is always 1% of the ETH that actually moved: a swap stopped early by its
   price limit or by thin liquidity pays on the filled part only (see *Fee arithmetic*).
2. **Buy cap.** For 10 minutes from the pool's first swap (`windowEndsAt(poolId)`, zero until then), each
   wallet may buy at most 1.0% of the token's total supply in total. A buy that would push a wallet past the
   cap reverts with `BuyCapExceeded`. Sells are never capped.
3. **Jar and buyback.** Another 1.0% of the ETH side of every swap goes into the pool's jar (`jar(poolId)`)
   held by the hook. Whenever the jar holds at least 0.1 ETH, `buyback(poolId)` — callable by anyone — spends
   the jar buying the pool's token from that pool and burns what it bought. The buy may not push the price
   more than a fixed band below the block's opening price (`BUYBACK_SQRT_PRICE_BAND_BPS`, 1% of the sqrt
   price, about 2% of the price); whatever the band does not let it spend stays in the jar for a later
   buyback. The hook also attempts the buyback automatically inside the swap that fills the jar; if that
   attempt fails for any reason the swap still succeeds, the jar waits, and swaps on that pool do not retry
   automatically for `AUTO_BUYBACK_RETRY_DELAY` (5 minutes) — `buyback(poolId)` is never delayed.
4. **Pause.** The owner may `pause()` and `unpause()` swaps on every pool using the hook (`paused()` view).
   Liquidity callbacks are not enabled, so liquidity can always be added or removed, paused or not.

The owner has no other power: no fee setter, no sweep, no signer, no upgrade path. Every number above is a
`public constant` on the hook (`FEE_BPS`, `JAR_BPS`, `BUY_WINDOW`, `BUY_CAP_BPS`, `BUYBACK_THRESHOLD`,
`BUYBACK_SQRT_PRICE_BAND_BPS`, `AUTO_BUYBACK_RETRY_DELAY`).

Enabled callbacks (and therefore the address bits the deployment must carry): `afterInitialize`,
`beforeSwap`, `afterSwap`, `beforeSwapReturnDelta`, `afterSwapReturnDelta`. Nothing else.

### Interface

| Function | Who | What |
| --- | --- | --- |
| `claimFees()` | anyone | redeem `pendingFees()` claims to `feeRecipient` |
| `buyback(bytes32 poolId)` | anyone | spend the pool's jar (≥ 0.1 ETH) on its token and burn it, within the band |
| `jar(bytes32 poolId)` | view | ETH collected for the pool's buybacks (`jarClaims(poolId)` is the part held as claims) |
| `windowEndsAt(bytes32 poolId)` | view | end of the pool's buy-cap window; 0 until its first swap |
| `pause()` / `unpause()` | owner | stop / resume swaps on every pool |
| `paused()` | view | whether swaps are paused |
| `isPool`, `poolKey`, `poolToken`, `windowOpen`, `buyCap`, `boughtDuringWindow`, `nextAutoBuybackAt`, `referencePrice`, `buybackSqrtPriceLimit`, `tokensBurned`, `tokensLocked`, `quoteSpecifiedEthFees` | view | per-pool / per-token details |

`poolId` is `PoolKey.toId()` (`keccak256(abi.encode(key))`), the id the PoolManager's `Initialize` event
carries.

## Deployment: why there are two contracts

A v4 hook must live at an address whose low 14 bits encode its permissions, so it has to be created with a
mined CREATE2 salt. The launch deploys **`PondsideGuardDeployer`**; it fixes the hook's constructor arguments
(and the resulting init code hash, as an immutable) and lets anyone deploy the hook once with a salt mined
against the deployer's own address.

Constructor of `PondsideGuardDeployer` (3 arguments, no external calls):

| # | Argument | Value for this launch |
| --- | --- | --- |
| 1 | `poolManager_` | `0x8366a39CC670B4001A1121B8F6A443A643e40951` |
| 2 | `owner_` | `$owner` |
| 3 | `feeRecipient_` | `$owner` |

`PondsideGuard` itself has the same three constructor arguments; the deployer passes them through.

### After launch

1. Mine a salt against the deployed deployer address (no transaction is sent):

   ```sh
   PONDSIDE_DEPLOYER=0x<deployer> forge script script/MineSalt.s.sol --rpc-url <robinhood-chain-rpc>
   ```

   The script prints the salt and the resulting hook address. `PondsideGuardDeployer.isValidSalt(bytes32)`
   and `predict(bytes32)` let you double-check on chain.

2. Anyone sends one transaction: `PondsideGuardDeployer.deploy(bytes32 salt)`. A wrong salt reverts with
   `HookAddressNotValid`, so nothing broken can be deployed. The hook address is emitted in
   `PondsideGuardDeployed` and readable from `PondsideGuardDeployer.hook()`.

3. Initialize a pool with `PoolKey{currency0: address(0) (native ETH), currency1: <token>, fee, tickSpacing,
   hooks: <hook>}` on the PoolManager and add liquidity. The pool must be ETH / token: a pool whose
   `currency0` is not native ETH is refused (`PairMustBeNativeEth`), and so is one whose token does not answer
   `totalSupply()` (`TokenSupplyUnavailable`), because the buy cap reads it on every buy during the window.
   Any LP fee tier and tick spacing works, and any number of pools may use the hook — a pool someone else
   initializes with it neither blocks nor affects yours.

The hook does not read anything from the PoolManager at construction, so the deployer's constructor can be
rehearsed on an empty chain.

## Fee arithmetic

ETH is always `currency0`. Fees are charged on the ETH side only, never on the token.

| Swap | ETH is… | Where charged | Basis |
| --- | --- | --- | --- |
| Buy, exact input (ETH in) | specified | `beforeSwap` return delta | the ETH the pool actually receives, grossed up by 100/98; the trader pays it plus the fees (equal to the request when fully filled) |
| Buy, exact output (tokens out) | unspecified | `afterSwap` return delta | the ETH the pool needs, grossed up by 100/98; the trader pays it plus the fees |
| Sell, exact input (tokens in) | unspecified | `afterSwap` return delta | the ETH the pool pays out; the trader receives 98% |
| Sell, exact output (ETH out) | specified | `beforeSwap` return delta | the ETH the pool actually pays, grossed up by 100/98; the trader receives exactly the request when fully filled, otherwise 98% of what the pool paid |

Each share is `gross * 100 / 10000` (integer division; swaps below 100 wei of ETH pay nothing). The recipient
fee and the jar share are always equal. `quoteSpecifiedEthFees(int256)` previews the two shares of a fully
filled ETH-specified swap.

**How specified-ETH swaps are charged exactly.** A `beforeSwap` delta is fixed before the pool swaps, so a
hook that quotes it from the request overcharges whenever the pool fills less than the request (price limit
reached, liquidity exhausted). `PondsideGuard` instead runs the swap the PoolManager is about to run
(`simulateSwap`, callable only by the hook itself), reads the delta from the revert, and quotes the fee on
the ETH it saw. The real swap then fills exactly the same amount: a full fill because the fee-adjusted request
is the same, a partial fill because it is bounded by the same price limit on the same pool state. The
simulation roughly doubles the gas of exact-input buys and exact-output sells; exact-output buys and
exact-input sells are charged from the realised delta in `afterSwap` and are unaffected. If the simulation
reverts for the swap's own reasons (price limit already exceeded, no liquidity) the swap reverts with that
same error, wrapped by the PoolManager.

## Buyback price band

A buyback is an exact-input buy of the whole jar bounded by `sqrtPriceLimit = reference * 0.99`, where the
reference is the pool's sqrt price at the hook's first interaction in the current block (recorded in
`beforeSwap` and in `buyback`, see `referencePrice(poolId)`). Consequences:

- A trade in the same block that moves the price first cannot have the jar buy at the moved price: the
  automatic attempt after a large buy fails with `BuybackPriceOutOfBand` (caught, jar kept, retry deferred),
  and a manual `buyback(poolId)` in that block reverts with it.
- Against a thin or thinned book the buyback stops at the band and leaves the rest in the jar; the jar is
  spent over several blocks instead of at any price. The attacker's or LP's gain is bounded by about 2% of
  what the buyback spends in a block, below the 2% + 2% hook fee any round trip through the pool pays.
- In a deep pool 0.1 ETH never reaches the band and the whole jar is spent at once.

`buybackSqrtPriceLimit(poolId)` shows the limit a buyback would use right now.

## Assumptions and design choices

- **"Wallet" for the buy cap is `tx.origin`.** Swaps reach the PoolManager through routers, so the hook's
  `sender` is a router and would cap every user of that router together. Using the transaction origin
  identifies the signing wallet. Account-abstraction wallets whose transactions are submitted by a bundler or
  relayer share that submitter's origin, a contract wallet driven by several signers gets several caps, and
  anyone can split buys across EOAs. A v4 swap carries no authenticated end-user identity, so this is a
  per-wallet soft limit during ten minutes, not a security boundary.
- **The window starts at the first swap**, not at initialization: initialization is permissionless and a pool
  cannot trade before liquidity exists, so a clock started then could run out before trading opens. The first
  swap itself is already capped.
- **Cap basis is the token's live `totalSupply()`.** Buybacks that burn tokens lower it slightly. A token with
  fewer than 100 units of supply (or zero supply at swap time) has a cap of 0 during its window.
- **Burn.** The buyback offers the hook's whole balance of the token to `burn(uint256)`. Tokens the token
  refuses to burn (no `burn`, or one that reverts or does not reduce the balance) stay in the hook, counted in
  `tokensLocked(token)`, and are offered again at that token's next buyback; `tokensBurned(token)` counts
  what was destroyed. The hook has no function that can move them elsewhere; no dead-address transfer is used.
- **The hook's own swaps skip the hook.** The PoolManager does not call a hook for swaps the hook itself
  initiates, so neither the fee simulation nor the buyback pays a hook fee or counts against any wallet's cap.
- **Automatic buyback is best effort.** It is skipped (caught) if the caller's router has an ERC-20 synced for
  settlement at that moment, if the price is already outside the band, if the swap or token transfer fails,
  or if too little gas is left; the jar is then redeemed by `buyback(poolId)`. After a failed attempt, swaps
  on that pool skip the attempt for 5 minutes so a persistently failing buyback does not charge every trader
  for it. `buyback(poolId)` reverts while paused.
- **No exit for the jar other than a buyback.** By design the hook has no sweep. If a pool's token makes
  every buyback impossible (it blocks transfers to the hook, or all liquidity is gone for good) that pool's
  jar stays in the hook.
- **ETH custody.** The hook accepts ETH only from the PoolManager (`DirectEthNotAccepted` otherwise). Its ETH
  balance plus the sum of `jarClaims(poolId)` always equals the sum of `jar(poolId)`; recipient claims are
  tracked in `pendingFees()`.
- **Claims are minted to the hook, not the recipient,** so that `claimFees()` can redeem them for the
  recipient without any approval.
- **Pause is global.** One hook, one switch: pausing stops swaps on every pool that uses it.
- **No reentrancy surface.** All value movement happens inside a PoolManager unlock; re-entering `buyback()`
  or `claimFees()` from a token or recipient callback hits `AlreadyUnlocked`. `simulateSwap` and
  `selfBuyback` are callable only by the hook itself.

## Operational responsibilities

- **Owner** (`0x5Bff2a2FEcD1d6152676813b21346238733bEAB1`): pause swaps in an emergency and unpause them.
  Nothing else; the owner cannot touch fees, jars, pools or liquidity.
- **Fee recipient**: receives ETH automatically. If the recipient address is a contract that refuses ETH, fees
  accumulate as claims until `claimFees()` succeeds.
- **Anyone**: call `deploy(salt)` once after launch, then `buyback(poolId)` whenever `jar(poolId) >= 0.1 ether`
  and the automatic attempt did not run or was bounded, and `claimFees()` whenever `pendingFees() > 0`.
- **Pool creator**: initialize the pool with native ETH as `currency0` and a token that answers
  `totalSupply()`, then seed liquidity. The buy-cap window opens with the first swap.

## Repository layout

```
src/PondsideGuard.sol           the hook
src/PondsideGuardDeployer.sol   the contract the launch deploys
script/MineSalt.s.sol           pure salt miner + script to print the salt for a live deployer
test/                           Foundry tests (78) against a real PoolManager and v4 test routers
lib/                            vendored dependencies (see lib/VENDORED.md): v4-core, solmate Owned, forge-std
```

## Checks

```sh
forge build
forge test
forge fmt --check
```

Tests pass in any order, read no environment variables, and run with the verifier's fuzz seed. They cover
each swap mode's fee, partial fills of both ETH-specified swap modes (price limit and exhausted liquidity,
plus a fuzz over price limits), error pass-through from the simulation, claim minting and redemption
(recipient refusing ETH, PoolManager without ETH), the buy cap (at, above, cumulative, window boundary, lazy
window start, other wallets, sells), several pools on one hook (independent state, a junk pool initialized
first, same token in another fee tier), refused pools (non-ETH pair, token without `totalSupply`), automatic
and manual buybacks, the failed-buyback-does-not-revert path and its retry delay, claim-settled buybacks,
the price band (same-block sandwich, bounded next-block buyback with remainder, thinned liquidity, deep
pool), burn retry and the keep fallback for non-burnable tokens, pause semantics with liquidity removal,
deployer single use, wrong salts, address bits, and bytecode size limits.

Tests are not an audit. The hook custodies ETH between swaps and buybacks; an independent adversarial review
is recommended before relying on it with significant value.
