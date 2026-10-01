// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, stdError} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {Pool} from "v4-core/src/libraries/Pool.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {TaxyHook} from "src/TaxyHook.sol";
import {TaxyToken} from "src/TaxyToken.sol";
import {SettlementRouter} from "./helpers/SettlementRouter.sol";

/// @dev Burns the caller's native-ETH claims and pays the ETH out, as a reviewed redemption router would.
contract ClaimRedeemer is IUnlockCallback {
    IPoolManager public immutable manager;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function redeem(uint256 amount) external {
        manager.unlock(abi.encode(msg.sender, amount));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "manager only");
        (address owner, uint256 amount) = abi.decode(data, (address, uint256));
        manager.burn(owner, 0, amount);
        manager.take(Currency.wrap(address(0)), owner, amount);
        return "";
    }
}

/// @dev Drives a token-only launch pool on the real PoolManager. The manager starts with no ETH, so
/// buys alternate between the direct-payment branch and the native-claim branch as sells, redemptions
/// and liquidity changes move its balance. Every action predicts the branch from the manager's balance
/// before the call and records only observed payments in the ghost ledger.
contract TaxyClaimFallbackHandler is Test {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    address public constant RECIPIENT = 0x047F606fD5b2BaA5f5C6c4aB8958E45CB6B054B7;
    uint160 private constant SELL_LIMIT = TickMath.MAX_SQRT_PRICE - 1;
    /// @dev Actor positions sit below the starting price like the seed. They deposit ETH only while
    /// the pool already holds some, so the manager keeps returning to the ETH-poor state under test.
    int24 public constant LP_LOWER = -6000;
    int24 public constant LP_UPPER = -60;
    IPoolManager public immutable manager;
    TaxyToken public immutable token;
    SettlementRouter public immutable router;
    ClaimRedeemer public immutable redeemer;
    PoolKey private key;
    address[3] public actors;
    uint256[3] public liquidity;

    // Ghost ledger. expectedFees applies the 4% specification to each gross amount; the other two
    // record what the recipient was actually paid or credited.
    uint256 public expectedFees;
    uint256 public directPaid;
    uint256 public claimsMinted;
    uint256 public redeemed;
    uint256 public swaps;
    uint256 public claimSwaps;
    uint256 public directSwaps;
    uint256 public exactOutputSells;
    uint256 public refusedExactOutputSells;
    uint256 public refusedSellsAtPriceLimit;
    uint256 public partialTokenSells;
    uint256 public redemptions;
    uint256 public overRedemptionsRefused;
    uint256 public liquidityChanges;

    struct Snapshot {
        uint256 actorETH;
        uint256 actorToken;
        uint256 managerETH;
        uint256 managerToken;
        uint256 recipientETH;
        uint256 claims;
    }

    constructor(
        IPoolManager manager_,
        TaxyToken token_,
        SettlementRouter router_,
        ClaimRedeemer redeemer_,
        PoolKey memory key_,
        address[3] memory actors_
    ) {
        manager = manager_;
        token = token_;
        router = router_;
        redeemer = redeemer_;
        key = key_;
        actors = actors_;
    }

    /// @notice Buy t4 with ETH. The branch is predicted from the manager's ETH before the call: the
    /// router settles the buyer's ETH only after the swap, so afterSwap sees exactly that balance.
    function buy(uint256 actorSeed, uint256 amountSeed, bool exactInput) public {
        address actor = actors[actorSeed % 3];
        uint256 amount = bound(amountSeed, 1, 10 ether);
        Snapshot memory s = _snapshot(actor);
        vm.prank(actor);
        BalanceDelta delta = router.swap{value: 100 ether}(
            key, SwapParams(true, exactInput ? -int256(amount) : int256(amount), TickMath.MIN_SQRT_PRICE + 1)
        );
        uint256 gross = s.actorETH - actor.balance;
        assertEq(int256(delta.amount0()), -int256(gross), "buy ETH delta");
        if (exactInput) assertEq(gross, amount, "exact ETH input must fully execute");
        else assertEq(int256(delta.amount1()), int256(amount), "exact token output");
        assertEq(token.balanceOf(actor) - s.actorToken, uint256(int256(delta.amount1())), "buy token delta");
        assertEq(s.managerToken - token.balanceOf(address(manager)), uint256(int256(delta.amount1())));

        uint256 fee = gross * 400 / 10_000;
        uint256 paidNow = RECIPIENT.balance - s.recipientETH;
        uint256 mintedNow = manager.balanceOf(RECIPIENT, 0) - s.claims;
        assertEq(paidNow + mintedNow, fee, "fee must be paid exactly once, as ETH or as a claim");
        if (s.managerETH < fee) {
            assertEq(paidNow, 0, "an ETH-poor manager must not transfer");
            assertEq(mintedNow, fee, "the whole fee becomes a claim");
            assertEq(address(manager).balance - s.managerETH, gross, "the gross stays in the manager as backing");
            ++claimSwaps;
        } else {
            assertEq(mintedNow, 0, "a funded manager must not mint");
            assertEq(paidNow, fee, "a funded manager pays ETH");
            assertEq(address(manager).balance - s.managerETH, gross - fee, "net of the direct fee");
            ++directSwaps;
        }
        assertGe(address(manager).balance, manager.balanceOf(RECIPIENT, 0), "buy left claims unbacked");
        expectedFees += fee;
        directPaid += paidNow;
        claimsMinted += mintedNow;
        ++swaps;
        assertSettled();
    }

    /// @notice Sell t4 for ETH. Exact ETH output may legitimately be unfillable from a drained pool;
    /// that refusal must be the hook's own PartialFillNotSupported and must move nothing.
    function sell(uint256 actorSeed, uint256 amountSeed, bool exactInput) public {
        address actor = actors[actorSeed % 3];
        Snapshot memory s = _snapshot(actor);
        (uint160 price,,,) = manager.getSlot0(key.toId());
        if (exactInput) {
            // Sells may exceed buys so that the pool is drained regularly.
            uint256 amount = bound(amountSeed, 1, s.actorToken < 30 ether ? s.actorToken : 30 ether);
            if (price >= SELL_LIMIT) {
                _expectPriceLimitRefusal(actor, s, price, -int256(amount));
                return;
            }
            vm.prank(actor);
            BalanceDelta delta = router.swap(key, SwapParams(false, -int256(amount), SELL_LIMIT));
            uint256 sold = uint256(-int256(delta.amount1()));
            assertLe(sold, amount, "exact token input cannot overfill");
            if (sold != amount) {
                // v4 fills a token-specified sell only as far as the pool's ETH reaches. The hook must
                // then charge 4% of the ETH actually delivered, which _checkSell verifies.
                (uint160 priceAfter,,,) = manager.getSlot0(key.toId());
                assertEq(priceAfter, SELL_LIMIT, "a partial token fill is only legitimate once the pool has no ETH");
                ++partialTokenSells;
            }
            _checkSell(actor, s, delta);
        } else {
            uint256 amount = bound(amountSeed, 1, 10 ether);
            if (price >= SELL_LIMIT) {
                _expectPriceLimitRefusal(actor, s, price, int256(amount));
                return;
            }
            vm.prank(actor);
            try router.swap(key, SwapParams(false, int256(amount), SELL_LIMIT)) returns (BalanceDelta delta) {
                assertEq(int256(delta.amount0()), int256(amount), "exact ETH output is net of the fee");
                _checkSell(actor, s, delta);
                ++exactOutputSells;
            } catch (bytes memory reason) {
                assertEq(reason, partialFillRevert(), "only an unfillable ETH request may be refused");
                _assertUnchanged(actor, s);
                ++refusedExactOutputSells;
                assertSettled();
            }
        }
    }

    /// @notice The recipient redeems a bounded share of its claims. Redeeming one wei more than it
    /// holds must always fail first, so every call covers the over-redemption path.
    function redeem(uint256 amountSeed) public {
        Snapshot memory s = _snapshot(RECIPIENT);
        vm.prank(RECIPIENT);
        manager.approve(address(redeemer), 0, s.claims + 1);
        vm.expectRevert(stdError.arithmeticError);
        vm.prank(RECIPIENT);
        redeemer.redeem(s.claims + 1);
        ++overRedemptionsRefused;
        _assertUnchanged(RECIPIENT, s);

        if (s.claims == 0) {
            vm.prank(RECIPIENT);
            manager.approve(address(redeemer), 0, 0);
            assertSettled();
            return;
        }
        uint256 amount = bound(amountSeed, 1, s.claims);
        vm.prank(RECIPIENT);
        manager.approve(address(redeemer), 0, amount);
        vm.prank(RECIPIENT);
        redeemer.redeem(amount);
        assertEq(RECIPIENT.balance - s.recipientETH, amount, "redeemed ETH");
        assertEq(s.managerETH - address(manager).balance, amount, "ETH leaves the manager");
        assertEq(s.claims - manager.balanceOf(RECIPIENT, 0), amount, "claims burned");
        assertEq(manager.allowance(RECIPIENT, address(redeemer), 0), 0, "allowance fully consumed");
        assertEq(token.balanceOf(RECIPIENT), 0, "redemption pays ETH only");
        redeemed += amount;
        ++redemptions;
        assertSettled();
    }

    /// @notice LP deposits and withdrawals. They must never pay a swap fee, mint a claim, or
    /// withdraw ETH that backs an outstanding claim.
    function changeLiquidity(uint256 actorSeed, uint256 amountSeed, bool remove) public {
        uint256 a = actorSeed % 3;
        bool withdrawing = remove && liquidity[a] != 0;
        uint256 amount = withdrawing ? bound(amountSeed, 1, liquidity[a]) : bound(amountSeed, 1 ether, 100 ether);
        _changeLiquidity(a, withdrawing ? -int256(amount) : int256(amount));
    }

    function closePositions() external {
        for (uint256 a; a < 3; ++a) {
            if (liquidity[a] != 0) _changeLiquidity(a, -int256(liquidity[a]));
        }
    }

    function redeemEverything() external {
        uint256 claims = manager.balanceOf(RECIPIENT, 0);
        if (claims == 0) return;
        Snapshot memory s = _snapshot(RECIPIENT);
        vm.prank(RECIPIENT);
        manager.approve(address(redeemer), 0, claims);
        vm.prank(RECIPIENT);
        redeemer.redeem(claims);
        assertEq(RECIPIENT.balance - s.recipientETH, claims);
        assertEq(s.managerETH - address(manager).balance, claims);
        assertEq(manager.balanceOf(RECIPIENT, 0), 0);
        redeemed += claims;
        ++redemptions;
        assertSettled();
    }

    function assertSettled() public view {
        address hook = address(key.hooks);
        assertEq(hook.balance, 0, "hook retained ETH");
        assertEq(token.balanceOf(hook), 0, "hook retained tokens");
        assertEq(manager.balanceOf(hook, 0), 0, "hook retained claims");
        assertEq(address(router).balance, 0, "router retained ETH");
        assertEq(token.balanceOf(address(router)), 0, "router retained tokens");
        assertEq(address(redeemer).balance, 0, "redeemer retained ETH");
        for (uint256 c; c < 2; ++c) {
            Currency currency = c == 0 ? key.currency0 : key.currency1;
            assertEq(manager.currencyDelta(hook, currency), 0, "hook debt");
            assertEq(manager.currencyDelta(address(router), currency), 0, "router debt");
            assertEq(manager.currencyDelta(address(redeemer), currency), 0, "redeemer debt");
        }
        assertEq(manager.getNonzeroDeltaCount(), 0, "unsettled manager delta");
        assertFalse(manager.isUnlocked(), "manager left unlocked");
    }

    /// @dev The exact bytes v4 bubbles up when afterSwap refuses a partial ETH-specified fill.
    function partialFillRevert() public view returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(key.hooks),
            IHooks.afterSwap.selector,
            abi.encodeWithSelector(TaxyHook.PartialFillNotSupported.selector),
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
    }

    function _checkSell(address actor, Snapshot memory s, BalanceDelta delta) private {
        uint256 gross = s.managerETH - address(manager).balance;
        uint256 fee = RECIPIENT.balance - s.recipientETH;
        assertEq(actor.balance - s.actorETH + fee, gross, "sell allocation");
        assertEq(fee, gross * 400 / 10_000, "sell fee is 4% of the AMM's ETH output");
        assertEq(int256(delta.amount0()), int256(actor.balance - s.actorETH), "sell ETH delta");
        assertEq(s.actorToken - token.balanceOf(actor), uint256(-int256(delta.amount1())), "sell token delta");
        assertEq(token.balanceOf(address(manager)) - s.managerToken, s.actorToken - token.balanceOf(actor));
        assertEq(manager.balanceOf(RECIPIENT, 0), s.claims, "a sell never mints a claim");
        assertGe(address(manager).balance, manager.balanceOf(RECIPIENT, 0), "sell left claims unbacked");
        expectedFees += fee;
        directPaid += fee;
        ++swaps;
        ++directSwaps;
        assertSettled();
    }

    function _changeLiquidity(uint256 a, int256 amount) private {
        Snapshot memory s = _snapshot(actors[a]);
        vm.prank(actors[a]);
        router.modifyLiquidity{value: amount > 0 ? 200 ether : 0}(
            key, ModifyLiquidityParams(LP_LOWER, LP_UPPER, amount, bytes32(a + 1))
        );
        if (amount > 0) liquidity[a] += uint256(amount);
        else liquidity[a] -= uint256(-amount);
        assertEq(RECIPIENT.balance, s.recipientETH, "liquidity changes must not pay swap fees");
        assertEq(manager.balanceOf(RECIPIENT, 0), s.claims, "liquidity changes must not mint claims");
        assertGe(address(manager).balance, manager.balanceOf(RECIPIENT, 0), "LP change left claims unbacked");
        ++liquidityChanges;
        assertSettled();
    }

    function _expectPriceLimitRefusal(address actor, Snapshot memory s, uint160 price, int256 amount) private {
        vm.expectRevert(abi.encodeWithSelector(Pool.PriceLimitAlreadyExceeded.selector, price, SELL_LIMIT));
        vm.prank(actor);
        router.swap(key, SwapParams(false, amount, SELL_LIMIT));
        _assertUnchanged(actor, s);
        ++refusedSellsAtPriceLimit;
        assertSettled();
    }

    function _assertUnchanged(address actor, Snapshot memory s) private view {
        assertEq(abi.encode(_snapshot(actor)), abi.encode(s), "a refused call moved funds");
    }

    function _snapshot(address actor) private view returns (Snapshot memory) {
        return Snapshot(
            actor.balance,
            token.balanceOf(actor),
            address(manager).balance,
            token.balanceOf(address(manager)),
            RECIPIENT.balance,
            manager.balanceOf(RECIPIENT, 0)
        );
    }
}

contract TaxyClaimFallbackTest is Test {
    using StateLibrary for IPoolManager;

    address private constant RECIPIENT = 0x047F606fD5b2BaA5f5C6c4aB8958E45CB6B054B7;
    uint160 private constant ONE = 79228162514264337593543950336;
    int256 private constant SEED_LIQUIDITY = 1_000_000 ether;
    IPoolManager private manager;
    TaxyHook private hook;
    TaxyToken private token;
    SettlementRouter private router;
    ClaimRedeemer private redeemer;
    TaxyClaimFallbackHandler private handler;
    PoolKey private key;
    address[3] private actors;
    uint256 private totalETH;
    uint256 private recipientInitialETH;

    function setUp() public {
        manager = IPoolManager(address(new PoolManager(address(this))));
        token = new TaxyToken();
        hook = _deployHook();
        router = new SettlementRouter(manager);
        redeemer = new ClaimRedeemer(manager);
        key = PoolKey(Currency.wrap(address(0)), Currency.wrap(address(token)), 3000, 60, IHooks(address(hook)));
        manager.initialize(key, ONE);
        token.approve(address(router), type(uint256).max);
        // Entirely below the starting price: the position holds only t4, as a token-only launch does.
        router.modifyLiquidity(key, ModifyLiquidityParams(-6000, -60, SEED_LIQUIDITY, bytes32(0)));
        assertEq(address(manager).balance, 0, "fixture must start with no native reserves");
        for (uint256 a; a < 3; ++a) {
            actors[a] = address(uint160(0xC100 + a));
            token.transfer(actors[a], 1_000_000 ether);
            vm.deal(actors[a], 1_000_000 ether);
            vm.prank(actors[a]);
            token.approve(address(router), type(uint256).max);
        }
        vm.deal(address(this), 1_000 ether);
        handler = new TaxyClaimFallbackHandler(manager, token, router, redeemer, key, actors);
        totalETH = _sumETH();
        recipientInitialETH = RECIPIENT.balance;
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = TaxyClaimFallbackHandler.buy.selector;
        selectors[1] = TaxyClaimFallbackHandler.sell.selector;
        selectors[2] = TaxyClaimFallbackHandler.redeem.selector;
        selectors[3] = TaxyClaimFallbackHandler.changeLiquidity.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_everyFeeIsETHOrABackedClaimOwnedByTheRecipient() public view {
        assertEq(_sumETH(), totalETH, "ETH conservation");
        uint256 claims = manager.balanceOf(RECIPIENT, 0);
        assertEq(RECIPIENT.balance, recipientInitialETH + handler.directPaid() + handler.redeemed(), "recipient ETH");
        assertEq(claims, handler.claimsMinted() - handler.redeemed(), "outstanding claims");
        assertEq(handler.directPaid() + handler.claimsMinted(), handler.expectedFees(), "observed fees equal 4%");
        assertGe(address(manager).balance, claims, "claims must always be backed by manager ETH");
        assertEq(token.balanceOf(RECIPIENT), 0, "fees must never be tokens");
        assertEq(manager.balanceOf(address(hook), 0), 0, "hook must not hold claims");
        assertEq(manager.balanceOf(address(router), 0), 0, "router must not hold claims");
        assertEq(manager.balanceOf(address(redeemer), 0), 0, "redeemer must not hold claims");
        assertEq(manager.balanceOf(address(this), 0), 0, "LP must not hold claims");
        uint256 balances = token.balanceOf(address(this)) + token.balanceOf(address(manager));
        for (uint256 a; a < 3; ++a) {
            assertEq(manager.balanceOf(actors[a], 0), 0, "traders must not hold claims");
            balances += token.balanceOf(actors[a]);
            (uint128 position,,) = manager.getPositionInfo(
                key.toId(), address(router), handler.LP_LOWER(), handler.LP_UPPER(), bytes32(a + 1)
            );
            assertEq(uint256(position), handler.liquidity(a), "LP position differs from deposits minus withdrawals");
        }
        assertEq(balances, 1_000_000_000 ether, "token conservation");
        assertEq(token.totalSupply(), 1_000_000_000 ether, "supply immutable");
        handler.assertSettled();
    }

    /// @dev Every LP leaves, then the recipient redeems everything: claims stay backed throughout and
    /// the recipient ends with exactly 4% of every gross amount.
    function afterInvariant() public virtual {
        handler.closePositions();
        router.modifyLiquidity(key, ModifyLiquidityParams(-6000, -60, -SEED_LIQUIDITY, bytes32(0)));
        assertEq(manager.getLiquidity(key.toId()), 0, "all liquidity withdrawn");
        assertGe(address(manager).balance, manager.balanceOf(RECIPIENT, 0), "LP exit left claims unbacked");
        invariant_everyFeeIsETHOrABackedClaimOwnedByTheRecipient();
        handler.redeemEverything();
        assertEq(manager.balanceOf(RECIPIENT, 0), 0, "claims fully redeemed");
        assertEq(RECIPIENT.balance, recipientInitialETH + handler.expectedFees(), "recipient ends with every fee");
        invariant_everyFeeIsETHOrABackedClaimOwnedByTheRecipient();
    }

    function test_handlerExercisesEveryBranchDeterministically() public {
        handler.redeem(1); // nothing to redeem yet: only the over-redemption refusal runs
        handler.buy(0, 1 ether, true); // manager holds 0 ETH: claim branch
        handler.buy(1, 1 ether, false); // manager now holds ~1 ETH: direct branch
        handler.sell(0, 1 ether, true);
        handler.sell(1, 0.1 ether, false); // fillable exact ETH output
        handler.sell(2, 10 ether, false); // more ETH than the pool holds: refused by the hook
        handler.changeLiquidity(2, 50 ether, false);
        handler.redeem(0.02 ether);
        handler.changeLiquidity(2, 50 ether, true);
        handler.sell(0, 10 ether, true); // drains the remaining ETH and runs the price to the limit
        (uint160 price,,,) = manager.getSlot0(key.toId());
        assertEq(price, TickMath.MAX_SQRT_PRICE - 1, "fixture drained the pool");
        handler.sell(1, 1 ether, true); // refused by the pool at its price limit
        handler.sell(1, 1 ether, false);
        handler.buy(2, 1 ether, true); // walks back down into liquidity and mints a claim again
        assertEq(handler.claimSwaps(), 2);
        assertEq(handler.directSwaps(), 4);
        assertEq(handler.exactOutputSells(), 1);
        assertEq(handler.refusedExactOutputSells(), 1);
        assertEq(handler.refusedSellsAtPriceLimit(), 2);
        assertEq(handler.partialTokenSells(), 1);
        assertEq(handler.redemptions(), 1);
        assertEq(handler.overRedemptionsRefused(), 2);
        assertEq(handler.liquidityChanges(), 2);
        assertGt(handler.claimsMinted(), 0);
        assertGt(handler.directPaid(), 0);
        assertGt(handler.redeemed(), 0);
        afterInvariant();
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_branchFollowsManagerBalanceAgainstFee(uint96 rawManagerETH, uint96 rawAmount, bool exactInput)
        public
    {
        uint256 managerETH = bound(uint256(rawManagerETH), 0, 1 ether);
        vm.deal(address(manager), managerETH);
        uint256 recipientBefore = RECIPIENT.balance;
        uint256 actorBefore = actors[0].balance;
        handler.buy(0, bound(uint256(rawAmount), 25, 10 ether), exactInput);
        uint256 gross = actorBefore - actors[0].balance;
        uint256 fee = gross * 400 / 10_000;
        assertGt(fee, 0);
        if (managerETH < fee) {
            assertEq(manager.balanceOf(RECIPIENT, 0), fee, "shortfall mints the whole fee");
            assertEq(RECIPIENT.balance, recipientBefore, "shortfall transfers nothing");
            assertEq(address(manager).balance, managerETH + gross);
        } else {
            assertEq(manager.balanceOf(RECIPIENT, 0), 0, "funded manager mints nothing");
            assertEq(RECIPIENT.balance - recipientBefore, fee, "funded manager pays ETH");
            assertEq(address(manager).balance, managerETH + gross - fee);
        }
        assertGe(address(manager).balance, manager.balanceOf(RECIPIENT, 0));
    }

    function test_zeroFeeBuyAtZeroETHMintsNoClaimAndEmitsOnlySwapFeePaid() public {
        vm.recordLogs();
        vm.prank(actors[0]);
        BalanceDelta delta = router.swap{value: 1 ether}(key, SwapParams(true, -24, TickMath.MIN_SQRT_PRICE + 1));
        assertEq(int256(delta.amount0()), -24);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 hookEvents;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(hook)) continue;
            assertEq(logs[i].topics[0], keccak256("SwapFeePaid(bytes32,address,bool,uint256,uint256)"));
            (, uint256 gross, uint256 fee) = abi.decode(logs[i].data, (bool, uint256, uint256));
            assertEq(gross, 24);
            assertEq(fee, 0);
            ++hookEvents;
        }
        assertEq(hookEvents, 1, "a zero fee emits no claim event");
        assertEq(manager.balanceOf(RECIPIENT, 0), 0);
        assertEq(RECIPIENT.balance, 0);
        assertEq(address(manager).balance, 24);
        handler.assertSettled();
    }

    function test_claimBranchEmitsSwapFeePaidThenSwapFeeClaimMinted() public {
        vm.recordLogs();
        vm.prank(actors[0]);
        router.swap{value: 1 ether}(key, SwapParams(true, -1 ether, TickMath.MIN_SQRT_PRICE + 1));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32[] memory topics = new bytes32[](2);
        uint256[] memory fees = new uint256[](2);
        uint256 hookEvents;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(hook)) continue;
            require(hookEvents < 2, "more than two hook events");
            topics[hookEvents] = logs[i].topics[0];
            assertEq(logs[i].topics[1], PoolId.unwrap(key.toId()), "pool id");
            if (hookEvents == 0) (,, fees[0]) = abi.decode(logs[i].data, (bool, uint256, uint256));
            else fees[1] = abi.decode(logs[i].data, (uint256));
            ++hookEvents;
        }
        assertEq(hookEvents, 2, "claim branch emits exactly two hook events");
        assertEq(topics[0], keccak256("SwapFeePaid(bytes32,address,bool,uint256,uint256)"));
        assertEq(topics[1], keccak256("SwapFeeClaimMinted(bytes32,uint256)"));
        assertEq(fees[0], 0.04 ether);
        assertEq(fees[1], 0.04 ether, "both events report the same fee");
        assertEq(manager.balanceOf(RECIPIENT, 0), 0.04 ether);
    }

    function test_directPaymentDrawnFromClaimBackingIsRestoredBySettlement() public {
        handler.buy(0, 1 ether, true);
        assertEq(address(manager).balance, 1 ether);
        assertEq(manager.balanceOf(RECIPIENT, 0), 0.04 ether);
        // 0.08 ETH fee <= 1 ETH balance: the take is funded by ETH that currently backs the pool and
        // the prior claim. The buyer's settlement in the same unlock restores both.
        handler.buy(1, 2 ether, true);
        assertEq(RECIPIENT.balance, 0.08 ether, "second fee paid directly");
        assertEq(manager.balanceOf(RECIPIENT, 0), 0.04 ether, "prior claim untouched");
        assertEq(address(manager).balance, 2.92 ether);
        assertGe(address(manager).balance - manager.balanceOf(RECIPIENT, 0), 0.96 ether + 1.92 ether);
    }

    function test_underfundedBuyerRollsBackDirectPaymentDrawnFromClaimBacking() public {
        handler.buy(0, 1 ether, true);
        uint256 actorETH = actors[1].balance;
        uint256 actorToken = token.balanceOf(actors[1]);
        (uint160 priceBefore,,,) = manager.getSlot0(key.toId());
        // The 0.08 ETH take succeeds mid-swap against the manager's 1 ETH, then settlement fails.
        vm.expectRevert();
        vm.prank(actors[1]);
        router.swap{value: 0.5 ether}(key, SwapParams(true, -2 ether, TickMath.MIN_SQRT_PRICE + 1));
        assertEq(RECIPIENT.balance, 0, "rolled-back payment");
        assertEq(manager.balanceOf(RECIPIENT, 0), 0.04 ether, "prior claim intact");
        assertEq(address(manager).balance, 1 ether, "backing intact");
        assertEq(actors[1].balance, actorETH);
        assertEq(token.balanceOf(actors[1]), actorToken);
        (uint160 priceAfter,,,) = manager.getSlot0(key.toId());
        assertEq(priceBefore, priceAfter);
        handler.assertSettled();
    }

    function test_thirdPartyCannotMoveOrBurnRecipientClaims() public {
        handler.buy(0, 1 ether, true);
        address attacker = address(0xBAD);
        vm.prank(attacker);
        vm.expectRevert(stdError.arithmeticError);
        manager.transferFrom(RECIPIENT, attacker, 0, 0.04 ether);
        vm.prank(attacker);
        vm.expectRevert(stdError.arithmeticError);
        redeemer.redeem(0.04 ether);
        // The hook itself was never approved and holds nothing to burn with.
        assertEq(manager.allowance(RECIPIENT, address(hook), 0), 0);
        assertFalse(manager.isOperator(RECIPIENT, address(hook)));
        assertEq(manager.balanceOf(RECIPIENT, 0), 0.04 ether);
        assertEq(manager.balanceOf(attacker, 0), 0);
        assertEq(attacker.balance, 0);
    }

    function test_fullExitLeavesClaimsBackedAndRedeemable() public {
        handler.buy(0, 1 ether, true);
        uint256 bought = token.balanceOf(actors[0]) - 1_000_000 ether;
        handler.sell(0, bought, true); // sells everything bought: most of the pool's ETH leaves
        uint256 claims = manager.balanceOf(RECIPIENT, 0);
        assertEq(claims, 0.04 ether);
        assertLt(address(manager).balance, 0.1 ether, "pool nearly drained");
        assertGe(address(manager).balance, claims, "backing survives the drain");
        afterInvariant();
        assertEq(RECIPIENT.balance, 0.04 ether + handler.directPaid());
    }

    function _sumETH() private view returns (uint256 total) {
        total = address(this).balance + address(manager).balance + RECIPIENT.balance + address(hook).balance
            + address(router).balance + address(redeemer).balance;
        for (uint256 a; a < 3; ++a) {
            total += actors[a].balance;
        }
    }

    function _deployHook() private returns (TaxyHook) {
        bytes memory creation = abi.encodePacked(type(TaxyHook).creationCode, abi.encode(manager));
        bytes32 hash = keccak256(creation);
        for (uint256 i; i < 200_000; ++i) {
            bytes32 salt = bytes32(i);
            address predicted =
                address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, hash)))));
            if (uint160(predicted) & Hooks.ALL_HOOK_MASK != 0x20cc) continue;
            address deployed;
            assembly ("memory-safe") {
                deployed := create2(0, add(creation, 32), mload(creation), salt)
            }
            require(deployed != address(0), "hook deployment failed");
            return TaxyHook(deployed);
        }
        revert("no hook salt found");
    }

    receive() external payable {}
}
