# Additional adversarial tests

These suites extend the existing tests without changing the implementation or build configuration.

- `TaxyHookCallbacks.t.sol` checks every callback's caller authentication, disabled callbacks,
  unsupported pools, repeated calls, signed accounting bounds, and fee rounding. A small native
  transfer recorder isolates arithmetic near `int128.max`; it does not model v4 settlement.
- `TaxyLifecycle.t.sol` uses the vendored, real v4 PoolManager and a mined hook address. Three
  funded actors share two pools with different prices and LP fees. Random sequences mix all four
  swap modes, liquidity deposits/withdrawals, rejected slippage checks, and buy/sell round trips.
  Assertions reconcile actual balances, immediate ETH fees, zero token fees, LP positions, and
  zero outstanding manager deltas. Each campaign ends by withdrawing every actor's LP position.
  Separate tests check event fields, one-wei requests, and rollback when token settlement fails
  after the hook has attempted fee payment.
- `TaxyHookPresettlement.t.sol` seeds a real pool entirely with tokens and no native reserves.
  Prepaid buys must deliver the 4% fee during the swap, return unused ETH credit, and clear all
  manager deltas. Empty pools execute no token-specified exchange and retain no swap fee.
- `TaxyClaimFallback.t.sol` targets the native-claim fallback added after the manager-balance
  shortfall finding. A token-only launch pool on the real PoolManager starts with no ETH, so random
  sequences of buys, sells, recipient redemptions and LP changes move the manager's balance across
  the fee and alternate between direct ETH payment and ERC-6909 claim minting. The handler predicts
  the branch from the balance before each call, records only observed payments, and tolerates
  exactly two refusals: the hook's own `PartialFillNotSupported` for an unfillable exact-ETH-output
  sell and the pool's price-limit refusal once it holds no ETH. Invariants: every fee is paid once as
  ETH or as a claim, only the recipient ever holds native claims, manager ETH always covers the
  outstanding claims, and after every LP exits the recipient can redeem everything and ends with
  exactly 4% of every gross amount. Unit tests pin zero-fee buys at zero ETH, both events on the
  claim branch, direct payment drawn from claim backing and its rollback when the buyer cannot
  settle, third-party claim transfer/burn refusal, and a near-complete drain of the pool.
- `TaxyTokenEdges.t.sol` pins zero, one wei, full supply, maximum uint, self transfers, allowance
  exhaustion/revocation, and failed delegated transfers. Split-transfer fuzzing checks no token tax.
- `TaxyTokenInvariant.t.sol` tracks independent balances and allowances for four actors through
  transfers, approvals, delegated spends, invalid calls, and attempted administrative changes.

New fuzz properties run 1,000 cases. New invariant campaigns run 256 sequences of 64 handler calls
with unexpected reverts treated as failures, configured inline in the test files. Pinned sequences
exercise every handler, including successful nonzero operations and expected failures.

Run `forge build` and `forge test` with the dependencies already vendored in this repository.
No RPC, environment mutation, network, FFI, or new dependency is required. Build artifacts can be
kept inside the disposable scratch area with
`FOUNDRY_OUT=test/scratch/build FOUNDRY_CACHE_PATH=test/scratch/cache`.

Scope limits: callback recorder tests are unit tests; settlement claims rely on the real-manager
integration suites. Random lifecycle swaps are bounded to keep both pools liquid; the original
suite separately covers partial fills and recipient rejection/reentrancy. These checks do not
replace a fork rehearsal against the eventual chain's deployed manager, router, and recipient.
