# Local security review

Scope: `src/TaxyHook.sol`, `src/TaxyToken.sol`, their interaction with the vendored v4 `Hooks` and `PoolManager` accounting, and the supplied security checklist. This is a source review performed during implementation, not an external audit or a production deployment approval. No source change was required by this review.

## Accounting reviewed

Native ETH is always currency0. Define gross ETH as the buyer's total ETH debit, or the AMM's ETH output for a seller. The fee is `floor(gross / 25)`, including integer rounding.

| Swap | Fee calculation | Hook delta |
| --- | --- | --- |
| Exact ETH input `A` | `F = floor(A / 25)`; AMM input `A - F` | Positive specified `F` from `beforeSwap` |
| Exact token output, AMM ETH input `B` | `F = floor(B / 24)`; buyer pays `B + F` | Positive unspecified `F` from `afterSwap` |
| Exact token input, AMM ETH output `G` | `F = floor(G / 25)`; seller receives `G - F` | Positive unspecified `F` from `afterSwap` |
| Exact ETH output `N` | `F = floor(N / 24)`; AMM output `N + F` | Positive specified `F` from `beforeSwap` |

The gross-up identity is exact: if `B = 24q + r`, where `0 <= r < 24`, then `B + floor(B/24) = 25q + r`, whose fee divided by 25 rounds to `q`. The same identity applies to `N`. Rounding can produce two gross amounts with the same net amount; the inverse formula consistently selects the larger one at those boundaries.

`PoolManager.take(ETH, recipient, F)` creates a hook debt of exactly `F`. The positive native hook delta credits exactly `F`, returning the hook's manager balance to zero. The caller's delta is reduced by `F`. No ERC-20 fee, conversion trade, price oracle, accrued fee claim, or keeper is involved.

## Review matrix

| Area | Finding |
| --- | --- |
| Callback authorization | Every callback, including disabled callbacks, checks the immutable PoolManager caller. Callback `sender` is only an event field; neither it nor `hookData` authorizes funds movement. |
| Permissions and deployment | Address flags `0x20cc` encode initialization, before/after swap, and both swap delta returns. Constructor validation checks the actual address. An initialization callback requires deployed hook code before initialization succeeds. |
| Pool scope | Initialization and `beforeSwap` require native currency0, nonzero currency1, this hook, and static LP fees. PoolManager supplies the same key and parameters to the paired `afterSwap`. |
| Before-swap delta risk | Only the bounded native fee is returned as a specified delta. It cannot consume a nonzero exact input in full, redirect token output, replace the AMM swap, or be changed by an administrator. |
| Partial fills | ETH-specified swaps verify the actual native amount equals the adjusted request and revert otherwise. Token-specified swaps compute the fee from the actual executed native delta. |
| Integer bounds | Input bounds precede negation and signed casts. Grossed-up native output and final gross native amounts must fit positive int128. No decimals or spot-price conversion is used. |
| Recipient reentrancy | The swap guard is set in `beforeSwap` and remains set throughout the ETH transfer in `afterSwap`. Reentrant swaps through this hook revert, including swaps on another pool using the same hook. Sequential router swaps remain possible. |
| Transfer failure | PoolManager's checked native transfer reverts the entire transaction on recipient rejection or insufficient native balance. Fee payment and swap execution are atomic. |
| Administrative powers | Fee, recipient, manager, permissions, and logic have no setters, proxy, ownership, pause, mint, or upgrade path. No dynamic LP fee updates are exposed. |
| Token | The constructor mints exactly `10^27` units to its deployer. OpenZeppelin ERC-20 supplies ordinary transfers and allowances; no transfer tax, subsequent mint, or external burn exists. |
| Custody and approvals | The hook requests no approvals and normally retains no ETH, tokens, or manager credit. Forced donations cannot be recovered because there is no rescue function. |
| Unbounded work | No user-controlled loops, arbitrary targets, or arbitrary calls appear in the hook. The ETH recipient can nevertheless consume gas or reject payment. |

## Operational limits and remaining work

- Only pools configured with this hook charge the fee. Standard token transfers, hookless pools, and pools using other hooks do not. WETH and ERC-20/ERC-20 pairs are unsupported. Nonstandard fee-on-transfer, rebasing, or callback tokens have not been validated; the launch token is an ordinary ERC-20.
- Exact ETH input and exact ETH output swaps require full execution. A binding price limit or insufficient liquidity reverts those modes atomically. Routers must enforce their own minimum output, maximum input, and deadline; the fee does not prevent sandwiches or adverse price movement. Static pool LP fees are additional to the hook fee.
- Immediate payment happens before an ordinary router settles its new ETH input. PoolManager must already hold enough native ETH to transfer the fee. For large ETH-input trades, a router may need to pre-settle native credit within its unlock callback before calling `swap`; otherwise a solvent trader's swap can still fail at fee payment. Pre-settlement must use PoolManager's native settlement rules and reconcile or refund unused credit before unlock returns.
- The fixed recipient must accept native ETH on the deployment chain. Smart-account code at that address can halt fee-bearing swaps by rejecting payment. There is no alternate recipient or administrative recovery. Fee rounding gives a zero fee below 25 wei gross, and zero-fee swaps do not call the recipient.
- The deployer must supply the correct chain's PoolManager, mine the exact hook permission bits, select a static fee tier and initial price, and provide liquidity. The token deployer receives the entire supply and is responsible for distribution. No funded-wallet action or chain transaction was performed for this assignment.
- Local real-PoolManager integration, failure-path, fuzz, and invariant tests accompany the implementation. Their execution results are reported separately by the final build/test run; this document does not substitute for those results. No mainnet fork rehearsal, Slither/Mythril run, formal verification, external audit, or production gas-cap certification is claimed. Independent adversarial review and a chain-specific deployment rehearsal remain release responsibilities.
