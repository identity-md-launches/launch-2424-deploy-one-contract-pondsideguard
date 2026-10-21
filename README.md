# PondsideGuard — standalone Uniswap v4 hook for Robinhood Chain

`PondsideGuard` is a Uniswap v4 hook with no token and no pool of its own. Anyone may initialize a new
native-ETH / token pool with it on the Robinhood Chain PoolManager; the first pool to do so binds the hook.
Composed with The Hooks Store block builder.

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
   and anyone may call it.
2. **Buy cap.** For 10 minutes after the pool opens (`windowEndsAt()`), each wallet may buy at most 1.0% of
   the token's total supply in total. A buy that would push a wallet past the cap reverts with
   `BuyCapExceeded`. Sells are never capped.
3. **Jar and buyback.** Another 1.0% of the ETH side of every swap goes into a jar (`jar()`) held by the
   hook. Whenever the jar holds at least 0.1 ETH, `buyback()` — callable by anyone — spends the whole jar
   buying the pool's token from this pool and burns what it bought. The hook also attempts the buyback
   automatically inside the swap that fills the jar; if that attempt fails for any reason the swap still
   succeeds and the jar waits for `buyback()`.
4. **Pause.** The owner may `pause()` and `unpause()` swaps (`paused()` view). Liquidity callbacks are not
   enabled, so liquidity can always be added or removed, paused or not.

The owner has no other power: no fee setter, no sweep, no signer, no upgrade path. Every number above is a
`public constant` on the hook (`FEE_BPS`, `JAR_BPS`, `BUY_WINDOW`, `BUY_CAP_BPS`, `BUYBACK_THRESHOLD`).

Enabled callbacks (and therefore the address bits the deployment must carry): `afterInitialize`,
`beforeSwap`, `afterSwap`, `beforeSwapReturnDelta`, `afterSwapReturnDelta`. Nothing else.

## Deployment: why there are two contracts

A v4 hook must live at an address whose low 14 bits encode its permissions, so it has to be created with a
mined CREATE2 salt. The launch deploys **`PondsideGuardDeployer`**; it fixes the hook's constructor arguments
and lets anyone deploy the hook once with a salt mined against the deployer's own address.

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

3. Initialize the pool with `PoolKey{currency0: address(0) (native ETH), currency1: <token>, fee, tickSpacing,
   hooks: <hook>}` on the PoolManager and add liquidity. The pool must be ETH / token: a pool whose
   `currency0` is not native ETH is refused (`PairMustBeNativeEth`). Only one pool can ever bind the hook
   (`AlreadyBound`). Any LP fee tier and tick spacing works.

The hook does not read anything from the PoolManager at construction, so the deployer's constructor can be
rehearsed on an empty chain.

## Fee arithmetic

ETH is always `currency0`. Fees are charged on the ETH side only, never on the token.

| Swap | ETH is… | Where charged | Basis |
| --- | --- | --- | --- |
| Buy, exact input (ETH in) | specified | `beforeSwap` return delta | the ETH the trader sends; the pool receives 98% |
| Buy, exact output (tokens out) | unspecified | `afterSwap` return delta | the ETH the pool needs, grossed up by 100/98; the trader pays it plus the fees |
| Sell, exact input (tokens in) | unspecified | `afterSwap` return delta | the ETH the pool pays out; the trader receives 98% |
| Sell, exact output (ETH out) | specified | `beforeSwap` return delta | the requested ETH grossed up by 100/98; the trader receives exactly what was requested |

Each share is `gross * 100 / 10000` (integer division; swaps below 100 wei of ETH pay nothing). The recipient
fee and the jar share are always equal. For specified-ETH swaps the fee is computed from the requested amount,
so a partial fill against a price limit still pays the fee on the requested amount — routers should size
their requests accordingly. `quoteSpecifiedEthFees(int256)` previews the two shares.

## Assumptions and design choices

- **"Wallet" for the buy cap is `tx.origin`.** Swaps reach the PoolManager through routers, so the hook's
  `sender` is a router and would cap every user of that router together. Using the transaction origin
  identifies the human wallet. Account-abstraction wallets whose transactions are submitted by a bundler
  share the bundler's origin; smart-wallet users could split buys across EOAs. This is a per-wallet soft limit
  during ten minutes, not a security boundary.
- **Cap basis is the token's live `totalSupply()`.** Buybacks that burn tokens lower it slightly.
- **Burn.** The buyback calls the token's `burn(uint256)`. If the token has no such function (or it does not
  reduce the hook's balance), the bought tokens stay in the hook forever: the hook has no function that can
  move them. `totalBurned()` and `totalLocked()` report both outcomes. No dead-address transfer is used.
- **Buyback price limit.** The buyback is an exact-input buy down to the minimum price; it consumes as much of
  the jar as the pool's liquidity allows and leaves any remainder in the jar. A buyback that buys nothing
  reverts (`BuybackBoughtNothing`); inside a swap that is caught and the jar is kept.
- **The hook's own swap skips the hook.** The PoolManager does not call a hook for swaps the hook itself
  initiates, so the buyback pays no hook fee and is not counted against any wallet's cap.
- **Automatic buyback is best effort.** It is skipped (caught) if the caller's router has an ERC-20 synced for
  settlement at that moment, if the swap or token transfer fails, or if too little gas is left; the jar is then
  redeemed by `buyback()`. `buyback()` reverts while paused.
- **ETH custody.** The hook accepts ETH only from the PoolManager (`DirectEthNotAccepted` otherwise). Its ETH
  balance plus `jarClaims()` always equals `jar()`; recipient claims are tracked in `pendingFees()`.
- **Claims are minted to the hook, not the recipient,** so that `claimFees()` can redeem them for the
  recipient without any approval.
- **No reentrancy surface.** All value movement happens inside a PoolManager unlock; re-entering `buyback()`
  or `claimFees()` from a token or recipient callback hits `AlreadyUnlocked`.

## Operational responsibilities

- **Owner** (`0x5Bff2a2FEcD1d6152676813b21346238733bEAB1`): pause swaps in an emergency and unpause them.
  Nothing else; the owner cannot touch fees, the jar, or liquidity.
- **Fee recipient**: receives ETH automatically. If the recipient address is a contract that refuses ETH, fees
  accumulate as claims until `claimFees()` succeeds.
- **Anyone**: call `deploy(salt)` once after launch, then `buyback()` whenever `jar() >= 0.1 ether` and the
  automatic attempt did not run, and `claimFees()` whenever `pendingFees() > 0`.
- **Pool creator**: initialize the pool with native ETH as `currency0` and seed liquidity. The buy-cap window
  starts at initialization, not at the first liquidity add.

## Repository layout

```
src/PondsideGuard.sol           the hook
src/PondsideGuardDeployer.sol   the contract the launch deploys
script/MineSalt.s.sol           pure salt miner + script to print the salt for a live deployer
test/                           Foundry tests (55) against a real PoolManager and v4 test routers
lib/                            vendored dependencies (see lib/VENDORED.md): v4-core, solmate Owned, forge-std
```

## Checks

```sh
forge build
forge test
forge fmt --check
```

Tests pass in any order, read no environment variables, and run with the verifier's fuzz seed. They cover
each swap mode's fee, claim minting and redemption (recipient refusing ETH, PoolManager without ETH), the buy
cap (at, above, cumulative, window boundary, other wallets, sells), automatic and manual buybacks, the
failed-buyback-does-not-revert path, claim-settled buybacks, the lock fallback for non-burnable tokens, pause
semantics with liquidity removal, deployer single use, wrong salts, address bits, and bytecode size limits.

Tests are not an audit. The hook custodies ETH between swaps and buybacks; an independent adversarial review
is recommended before relying on it with significant value.
