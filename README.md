# taxy / t4

An immutable Uniswap v4 hook that sends a **4% native-ETH swap fee** to
`0x047F606fD5b2BaA5f5C6c4aB8958E45CB6B054B7` during each successful swap.
The accompanying ERC-20 is named **taxy**, symbol **t4**, with 18 decimals and
exactly **1,000,000,000 tokens** (`10^27` minor units). Its no-argument constructor
mints the entire supply to its deployer, normally the launch factory.

Neither contract has an owner, fee setter, pause, mint-after-deployment function,
upgrade mechanism, recipient setter, withdrawal function or privileged exemption.
Token transfers are ordinary ERC-20 transfers; the fee belongs to the hook.

## Supported pools and assumptions

- Native ETH is `Currency.wrap(address(0))`, always currency0. Currency1 is the
  token. The intended launch pool is ETH/t4; this hook can serve multiple native
  ETH/standard-token pools. Each pool must explicitly include this hook.
- ERC-20/ERC-20 pools, including WETH/token pools, are rejected at initialization.
  There is no oracle, conversion route or third asset. The deployment chain must
  use ETH as its native currency and support Cancun EVM instructions.
- Static LP fees are supported; dynamic LP fees are rejected. The pool's LP and
  protocol fees are separate from the hook's 4% fee. A reasonable example pool
  configuration is LP fee `3000` (0.3%) and tick spacing `60`; neither is hardcoded
  into the hook.
- The hook cannot impose fees on hookless pools, other hooks, other DEXs, or
  direct token transfers. It does not authenticate an end user or trust hookData.
- Use standard, non-rebasing, non-fee-on-transfer tokens. The delivered t4 token
  meets those conditions. Exotic token behavior is not supported by this project.

## Fee definition and exact amounts

All arithmetic is in wei. Let **G** be the total ETH paid by a buyer, or the gross
ETH output from the AMM before this hook's fee on a sale. The fee is always
`F = floor(G * 400 / 10_000) = floor(G / 25)`. The recipient receives F immediately.
Rounding can produce a zero fee when G is below 25 wei.

| Swap request | AMM native amount | Fee | Trader native amount |
| --- | --- | --- | --- |
| Exact ETH input A, buying tokens | Input `A - floor(A/25)` | `floor(A/25)` | Pays exactly A |
| Exact token output, buying tokens | Actual input B | `floor(B/24)` | Pays `B + F` |
| Exact token input, selling tokens | Actual gross output G | `floor(G/25)` | Receives `G - F` |
| Exact ETH output N, selling tokens | Output `N + floor(N/24)` | `floor(N/24)` | Receives exactly N |

The inverse formula `floor(net/24)` satisfies the same gross 4% rule:
`floor((net + floor(net/24))/25) = floor(net/24)`. Integer rounding can make two
adjacent gross amounts correspond to the same net amount; the inverse chooses
the larger gross amount. For example, a 1 ETH exact-input buy sends 0.04 ETH to
the recipient and 0.96 ETH into the AMM. A sale producing 1 ETH gross pays the
recipient 0.04 ETH and delivers 0.96 ETH to the trader.

**Partial fills:** if ETH is the specified amount (exact-input buys or exact-output
sells), the hook requires the native AMM leg to fill completely. A price limit or
insufficient liquidity causing a partial fill reverts the entire swap and fee.
This is necessary because v4 fixes the specified-currency hook delta before
execution. If tokens are the specified amount, partial fills are allowed and the
fee uses only the ETH actually traded. Routers requiring an exact token output
must independently reject an incomplete fill. Zero-amount swap requests and
amounts outside the signed 128-bit accounting bounds are rejected.

## Accounting and callback permissions

`beforeInitialize` checks the native pair and static fee, authenticates the
PoolManager and returns its selector. This callback also ensures a predicted
pool cannot initialize successfully while the hook address has no code.

`beforeSwap` reserves a positive specified delta only when ETH is specified.
`afterSwap` checks the fill and charges an unspecified delta when ETH is
unspecified. It calls `poolManager.take(native, recipient, F)` directly. The
resulting hook debt of F is canceled by the positive hook return delta of F;
the swapper's native delta accounts for the fee. No ERC-20 is taken as a fee,
no ETH is retained by the hook, and no later claiming or upkeep is needed.

Only the constructor-supplied manager can call callbacks. A guard spans both swap
callbacks and remains active during ETH delivery, preventing nested swaps through
the same hook. Every disabled callback authenticates the caller and reverts.
The hook never calls `manager.swap` itself or handles an entire trade internally.

Enabled address flags are **`0x20cc` (8396)**: beforeInitialize, beforeSwap,
afterSwap, beforeSwapReturnDelta and afterSwapReturnDelta. All other flags are
false. The constructor validates the actual deployed address against these flags.

The design configuration is a direct implementation of the BaseHook pattern on
v4-core's IHooks interface, with no share token or administration:

```json
{
  "hook": "BaseHook",
  "name": "TaxyHook",
  "pausable": false,
  "currencySettler": false,
  "safeCast": true,
  "transientStorage": false,
  "shares": { "options": false },
  "permissions": {
    "beforeInitialize": true,
    "afterInitialize": false,
    "beforeAddLiquidity": false,
    "afterAddLiquidity": false,
    "beforeRemoveLiquidity": false,
    "afterRemoveLiquidity": false,
    "beforeSwap": true,
    "afterSwap": true,
    "beforeDonate": false,
    "afterDonate": false,
    "beforeSwapReturnDelta": true,
    "afterSwapReturnDelta": true,
    "afterAddLiquidityReturnDelta": false,
    "afterRemoveLiquidityReturnDelta": false
  },
  "inputs": {},
  "access": "none",
  "info": { "license": "MIT" }
}
```

`access: none` records the brief's immutable design, outside the reference
Wizard's administrative choices. No CurrencySettler helper is needed because
the hook only calls native `take`; routers settle the trader's debts. The hook
guard uses ordinary storage; v4-core itself requires transient storage.

## Build and check offline

```sh
forge build
forge test
forge fmt --check
```

Foundry is configured for **Solidity 0.8.26**, optimizer 200 runs, Cancun, and no
CBOR bytecode metadata. FFI and filesystem permissions are disabled. Dependencies
are ordinary source files under `lib/`, pinned by commit in
[DEPENDENCIES.json](DEPENDENCIES.json), with upstream licenses. No install,
submodule, fork RPC, environment variable, or network call is needed to run the
tests. The verifier must have the pinned compiler installed.

Tests deploy a real v4 PoolManager, mine and deploy the actual hook with CREATE2,
initialize pools, add/remove liquidity, and settle swaps. They cover both swap
directions and amount modes, fee conservation, partial fills, rounding, unauthorized
callbacks, recipient failures and reentrancy, fixed supply, and fuzzed amounts.
`test/helpers/` contains testing tools rather than production routers.

## Deployment parameters and responsibilities

| Contract | Constructor arguments | Notes |
| --- | --- | --- |
| `src/TaxyToken.sol:TaxyToken` | None | Factory receives all `10^27` units |
| `src/TaxyHook.sol:TaxyHook` | `IPoolManager manager` | Chain-specific deployed v4 PoolManager; code must exist |

The PoolManager is never hardcoded. The launch system should supply its chain's
manager, represented as `"$poolManager"` in its separate launch manifest. This
project does not create that external system's manifest or broadcast transactions.

The deployer must:

1. Select and verify the chain's v4 PoolManager, the launch factory/actual CREATE2
   caller, token distribution, LP fee, tick spacing, initial price, liquidity
   amounts and price range. The initial price is a deployment decision, not fixed
   at the 1:1 price used by local tests.
2. Build the reviewed code with the pinned settings. Mine a salt against
   `keccak256(abi.encodePacked(type(TaxyHook).creationCode, abi.encode(manager)))`
   and the **actual address executing CREATE2**. The predicted address's low 14
   bits must equal `0x20cc`. Remine if constructor args, compiler settings, code,
   or CREATE2 caller change.
3. Use the offline helper's explicit-argument entry point:
   `MineTaxySalt.run(address deployer, IPoolManager manager, uint256 start, uint256 attempts)`.
   It returns `(predicted, salt)` and searches at most 1,000,000 candidates per
   call. A batch with no match reverts; try the next start. It has no environment
   or wallet dependency. For example, with real addresses substituted:

   ```sh
   forge script script/MineTaxySalt.s.sol:MineTaxySalt \
     --sig 'run(address,address,uint256,uint256)' <create2-caller> <pool-manager> 0 200000
   ```

4. Deploy the token and hook and initialize ETH/t4 atomically through the launch
   factory. The hook constructor only takes the manager; no token address or
   recipient argument is required. Atomic hook deployment and initialization
   avoid third-party initialization between those actions. Before deployment,
   the initialization callback prevents successful initialization at the empty
   predicted hook address.
5. Rehearse against the actual manager/router on a fork, independently review
   the contracts, and verify deployed source and address flags. Check fee
   recipient delivery on the target chain. The helper only mines; it does not
   deploy, initialize, seed, or distribute funds.

Routers must account for hook-adjusted deltas, enforce minimum net output / maximum
total input and deadlines, and settle all manager credits and debts within unlock.
The fee is delivered before the ordinary post-swap input settlement. PoolManager
must therefore already hold enough native ETH for that payment. A router can
pre-settle native credit within unlock when reserves are insufficient; otherwise
the swap safely reverts. The test router demonstrates ordinary settlement only.

There are **no keepers, administrators or fee-claim operations**. Monitor
`SwapFeePaid(poolId, sender, zeroForOne, grossETH, feeETH)` and failed swaps; sender
is the manager's caller (usually a router), not an authenticated end user. A
recipient that rejects ETH makes fee-bearing swaps revert atomically. Nobody can
redirect the fee or rescue accidentally sent assets. No contract was deployed to
a public chain by this assignment. See [the security review](docs/SECURITY_REVIEW.md)
for review scope and outstanding release checks.

The v4 custom-accounting mechanism is described in
[Uniswap's official documentation](https://developers.uniswap.org/docs/protocols/v4/guides/custom-accounting).
The exact implementation relied on here is the pinned vendored v4-core source.
